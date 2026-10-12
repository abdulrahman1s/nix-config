#!/usr/bin/env python3
"""Build, export, upload, and rotate the private Nix binary cache."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote, urlencode

BUILT_PATHS = Path("/tmp/nix-cache-built-paths")
EVALUATION_PATHS = Path("/tmp/nix-cache-evaluation-paths")
UPLOADED_PATHS = Path("/tmp/nix-cache-uploaded-paths")
NEXT_FAILURES = Path("/tmp/nix-cache-failed-targets-next")
LOCK_DIGEST_KEY = "ci/flake-lock-hash"
PENDING_DIGEST_KEY = "ci/pending-flake-lock-hash"
PART_SIZE = 8 * 1024 * 1024
SINGLE_UPLOAD_LIMIT = 50 * 1024 * 1024


def github_escape(message: str) -> str:
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def log(message: str) -> None:
    print(message, flush=True)


def warning(message: str) -> None:
    log(f"::warning::{github_escape(message)}")


def error(message: str) -> None:
    log(f"::error::{github_escape(message)}")


@contextmanager
def group(title: str):
    log(f"::group::{github_escape(title)}")
    try:
        yield
    finally:
        log("::endgroup::")


def run(
    command: list[str], *, input_text: str | None = None
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        check=False,
        input=input_text,
        text=True,
        capture_output=True,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "(no command output)"
        raise RuntimeError(f"{shlex.join(command)} failed:\n{detail}")
    return result


def read_lines(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {line for line in path.read_text().splitlines() if line}


def write_lines(path: Path, lines: set[str] | list[str]) -> None:
    ordered = sorted(set(lines))
    path.write_text("".join(f"{line}\n" for line in ordered))


def record_built_paths() -> None:
    drv_path = os.environ.get("DRV_PATH")
    out_paths = os.environ.get("OUT_PATHS", "").split()
    if not drv_path or not out_paths:
        raise RuntimeError("post-build hook requires DRV_PATH and OUT_PATHS")
    with BUILT_PATHS.open("a") as records:
        fcntl.flock(records, fcntl.LOCK_EX)
        for path in out_paths:
            records.write(f"{drv_path}\t{path}\n")


class CacheClient:
    def __init__(self) -> None:
        self.base_url = os.environ.get("NIX_CACHE_URL", "").rstrip("/")
        token = os.environ.get("NIX_CACHE_WRITE_TOKEN", "")
        if not self.base_url.startswith("https://") or not token:
            raise RuntimeError("NIX_CACHE_URL and NIX_CACHE_WRITE_TOKEN are required")
        auth_fd, auth_name = tempfile.mkstemp(prefix="nix-cache-curl-")
        os.close(auth_fd)
        self.auth_config = Path(auth_name)
        self.auth_config.write_text(f'header = "Authorization: Bearer {token}"\n')
        self.auth_config.chmod(0o600)

    def close(self) -> None:
        self.auth_config.unlink(missing_ok=True)

    def read(self, key: str) -> tuple[int, bytes]:
        with tempfile.NamedTemporaryFile(prefix="nix-cache-response-") as response:
            result = subprocess.run(
                [
                    "curl",
                    "--netrc-file",
                    str(Path.home() / ".netrc"),
                    "--silent",
                    "--show-error",
                    "--retry",
                    "3",
                    "--retry-all-errors",
                    "--connect-timeout",
                    "10",
                    "--max-time",
                    "180",
                    "--output",
                    response.name,
                    "--write-out",
                    "%{http_code}",
                    f"{self.base_url}/{quote(key, safe='/')}",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode:
                raise RuntimeError(f"cache request failed: {result.stderr.strip()}")
            return int(result.stdout), Path(response.name).read_bytes()

    def send(
        self,
        method: str,
        key: str,
        *,
        data: bytes | None = None,
        path: Path | None = None,
        **query: str | int,
    ) -> bytes:
        url = f"{self.base_url}/upload/{quote(key, safe='/')}"
        if query:
            url += "?" + urlencode(query)
        payload = None
        if data is not None:
            payload_fd, payload_name = tempfile.mkstemp(prefix="nix-cache-payload-")
            os.close(payload_fd)
            payload = Path(payload_name)
            payload.write_bytes(data)
            path = payload
        command = [
            "curl",
            "--config",
            str(self.auth_config),
            "--silent",
            "--show-error",
            "--fail-with-body",
            "--retry",
            "3",
            "--retry-all-errors",
            "--connect-timeout",
            "10",
            "--max-time",
            "180",
            "--request",
            method,
            "--url",
            url,
        ]
        if path is not None:
            command.extend(("--data-binary", f"@{path}"))
        try:
            result = subprocess.run(command, check=False, capture_output=True)
        finally:
            if payload is not None:
                payload.unlink(missing_ok=True)
        if result.returncode:
            detail = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"upload of {key} failed: {detail}")
        return result.stdout

    def upload(self, key: str, path: Path) -> None:
        if path.stat().st_size <= SINGLE_UPLOAD_LIMIT:
            self.send("PUT", key, path=path)
            return

        upload_id = json.loads(self.send("POST", key, multipart="start"))["uploadId"]
        parts = []
        try:
            with path.open("rb") as source:
                part_number = 1
                while chunk := source.read(PART_SIZE):
                    part = json.loads(
                        self.send(
                            "PUT",
                            key,
                            data=chunk,
                            multipart="part",
                            uploadId=upload_id,
                            partNumber=part_number,
                        )
                    )
                    parts.append(part)
                    part_number += 1
            self.send(
                "POST",
                key,
                data=json.dumps({"parts": parts}).encode(),
                multipart="complete",
                uploadId=upload_id,
            )
        except Exception:
            try:
                self.send("DELETE", key, multipart="abort", uploadId=upload_id)
            except RuntimeError as exception:
                warning(f"Could not abort multipart upload for {key}: {exception}")
            raise

    def upload_metadata(self, key: str, contents: str) -> None:
        self.send("PUT", key, data=contents.encode())

    def purge_batch(self) -> int | None:
        with tempfile.NamedTemporaryFile(prefix="nix-cache-purge-") as response:
            result = subprocess.run(
                [
                    "curl",
                    "--config",
                    str(self.auth_config),
                    "--silent",
                    "--show-error",
                    "--retry",
                    "3",
                    "--retry-all-errors",
                    "--connect-timeout",
                    "10",
                    "--max-time",
                    "180",
                    "--request",
                    "DELETE",
                    "--output",
                    response.name,
                    "--write-out",
                    "%{http_code}",
                    f"{self.base_url}/admin/purge-cache",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode:
                raise RuntimeError(
                    f"cache purge request failed: {result.stderr.strip()}"
                )
            status = int(result.stdout)
            if status == 404:
                return None
            if status != 200:
                detail = Path(response.name).read_text(errors="replace").strip()
                raise RuntimeError(f"cache purge returned HTTP {status}: {detail}")
            return int(json.loads(Path(response.name).read_text())["deleted"])

    def purge(self) -> int | None:
        total = 0
        for _ in range(10000):
            deleted = self.purge_batch()
            if deleted is None:
                return None
            total += deleted
            if deleted == 0:
                return total
        raise RuntimeError("cache purge did not converge after 10,000 batches")


class Stats:
    def __init__(self) -> None:
        self.generation = "not checked"
        self.purged = 0
        self.missing = 0
        self.attempted = 0
        self.succeeded = 0
        self.failed = 0
        self.uploaded = 0
        self.system = "not run"

    def write_summary(self) -> None:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if not summary_path:
            return
        with Path(summary_path).open("a") as summary:
            summary.write(
                "### Nix cache refresh\n\n"
                "| Result | Count / status |\n"
                "| --- | ---: |\n"
                f"| Cache generation | {self.generation} |\n"
                f"| Purged R2 objects | {self.purged} |\n"
                f"| Missing package derivations | {self.missing} |\n"
                f"| Attempted package derivations | {self.attempted} |\n"
                f"| Successful package derivations | {self.succeeded} |\n"
                f"| Remembered failures | {self.failed} |\n"
                f"| Uploaded store paths | {self.uploaded} |\n"
                f"| Full NixOS build | {self.system} |\n"
            )


def configure_nix() -> None:
    config = json.loads(
        run(
            [
                "nix",
                "eval",
                "--impure",
                "--json",
                "--expr",
                "(import ./flake.nix).nixConfig",
            ]
        ).stdout
    )
    extra = "\n".join(
        (
            "extra-substituters = " + " ".join(config["extra-substituters"]),
            "extra-trusted-public-keys = "
            + " ".join(config["extra-trusted-public-keys"]),
        )
    )
    os.environ["NIX_CONFIG"] = f"{os.environ.get('NIX_CONFIG', '')}\n{extra}"


def ensure_generation(client: CacheClient, stats: Stats) -> tuple[str, bool]:
    status, _ = client.read("nix-cache-info")
    if status not in (200, 404):
        raise RuntimeError(f"private cache availability check returned HTTP {status}")

    digest = hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest()
    status, body = client.read(LOCK_DIGEST_KEY)
    if status == 200 and body.decode().strip() == digest:
        stats.generation = "current"
        log(f"✓ Cache generation already matches flake.lock ({digest[:12]})")
        return digest, True
    if status not in (200, 404):
        raise RuntimeError(f"cache generation check returned HTTP {status}")

    pending_status, pending_body = client.read(PENDING_DIGEST_KEY)
    if pending_status == 200 and pending_body.decode().strip() == digest:
        stats.generation = "resuming incomplete rotation"
        log(f"✓ Resuming incomplete cache generation {digest[:12]}")
        return digest, True
    if pending_status not in (200, 404):
        raise RuntimeError(
            f"pending cache generation check returned HTTP {pending_status}"
        )

    previous = body.decode().strip()[:12] if status == 200 else "untracked"
    with group("Rotate cache generation"):
        log(f"• flake.lock changed: {previous} → {digest[:12]}")
        purged = client.purge()
        if purged is None:
            warning(
                "The deployed cache Worker has no purge endpoint yet; skipping rotation "
                "and leaving the generation uncommitted"
            )
            stats.generation = "purge endpoint unavailable"
            return digest, False
        stats.purged = purged
        stats.generation = "rotated"
        client.upload_metadata(PENDING_DIGEST_KEY, digest + "\n")
        log(f"✓ Purged {purged} old R2 objects")
    return digest, True


def snapshot_built_records() -> list[tuple[str, str]]:
    if not BUILT_PATHS.exists():
        return []
    with BUILT_PATHS.open() as records:
        fcntl.flock(records, fcntl.LOCK_SH)
        return [
            tuple(line.split("\t", 1))
            for line in records.read().splitlines()
            if "\t" in line
        ]


def selected_built_paths() -> list[str]:
    records = snapshot_built_records()
    if not records:
        return []
    drvs = sorted({drv for drv, _ in records})
    derivations = json.loads(run(["nix", "derivation", "show", *drvs]).stdout)[
        "derivations"
    ]
    required_for_evaluation = read_lines(EVALUATION_PATHS)
    paths = set()
    for drv, path in records:
        derivation = derivations.get(Path(drv).name, derivations.get(drv))
        if derivation is None:
            raise RuntimeError(f"nix derivation show omitted {drv}")
        if path in required_for_evaluation or all(
            "hash" not in output for output in derivation["outputs"].values()
        ):
            paths.add(path)
    return sorted(paths - read_lines(UPLOADED_PATHS))


def export_paths(paths: list[str], cache: Path, signing_key: Path) -> None:
    cache.joinpath("nar").mkdir(parents=True)
    cache.joinpath("nix-cache-info").write_text(
        "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n"
    )
    key_name = signing_key.read_text().split(":", 1)[0]
    run(
        ["nix", "store", "sign", "--key-file", str(signing_key), "--stdin"],
        input_text="".join(f"{path}\n" for path in paths),
    )
    info = json.loads(
        run(["nix", "path-info", "--json", "--json-format", "1", *paths]).stdout
    )

    for path in paths:
        path_info = info[path]
        temporary_nar = cache / "nar" / f"{Path(path).name}.nar.zst"
        dump = subprocess.Popen(
            ["nix", "store", "dump-path", path], stdout=subprocess.PIPE
        )
        compression = subprocess.Popen(
            ["zstd", "--quiet", "-T1", "-3", "-o", str(temporary_nar)],
            stdin=dump.stdout,
        )
        if dump.stdout is not None:
            dump.stdout.close()
        compression_status = compression.wait()
        dump_status = dump.wait()
        if dump_status or compression_status:
            raise RuntimeError(f"failed to export {path}")

        file_hash = run(
            [
                "nix",
                "hash",
                "file",
                "--type",
                "sha256",
                "--base32",
                str(temporary_nar),
            ]
        ).stdout.strip()
        nar_name = f"{file_hash}.nar.zst"
        temporary_nar.rename(cache / "nar" / nar_name)
        signature = next(
            signature
            for signature in path_info["signatures"]
            if signature.startswith(f"{key_name}:")
        )
        references = " ".join(
            Path(reference).name for reference in path_info["references"]
        )
        narinfo = [
            f"StorePath: {path}",
            f"URL: nar/{nar_name}",
            "Compression: zstd",
            f"FileHash: sha256:{file_hash}",
            f"FileSize: {(cache / 'nar' / nar_name).stat().st_size}",
            f"NarHash: {path_info['narHash']}",
            f"NarSize: {path_info['narSize']}",
            f"References: {references}",
            f"Sig: {signature}",
        ]
        if path_info.get("ca"):
            narinfo.append(f"CA: {path_info['ca']}")
        store_hash = Path(path).name.split("-", 1)[0]
        cache.joinpath(f"{store_hash}.narinfo").write_text("\n".join(narinfo) + "\n")


def publish(
    client: CacheClient,
    stats: Stats,
    publish_lock: threading.Lock,
    *,
    include_failure_state: bool,
) -> int:
    with publish_lock:
        paths = selected_built_paths()
        if paths:
            log(f"▶ Publishing {len(paths)} newly built store paths")
            with (
                tempfile.TemporaryDirectory(prefix="nix-binary-cache-") as cache_dir,
                tempfile.NamedTemporaryFile(
                    mode="w", prefix="nix-cache-signing-key-"
                ) as signing_key,
            ):
                os.chmod(signing_key.name, 0o600)
                signing_key.write(os.environ["NIX_CACHE_SIGNING_KEY"] + "\n")
                signing_key.flush()
                cache = Path(cache_dir)
                export_paths(paths, cache, Path(signing_key.name))
                nars = sorted((cache / "nar").glob("*.nar.zst"))
                narinfos = sorted(cache.glob("*.narinfo"))
                for path in nars:
                    client.upload(f"nar/{path.name}", path)
                client.upload("nix-cache-info", cache / "nix-cache-info")
                for path in narinfos:
                    client.upload(path.name, path)
            write_lines(UPLOADED_PATHS, read_lines(UPLOADED_PATHS) | set(paths))
            stats.uploaded += len(paths)
            log(f"✓ Uploaded {len(paths)} NARs and signed narinfo files")
        if include_failure_state:
            client.upload("ci/failed-targets", NEXT_FAILURES)
        return len(paths)


class IncrementalUploader:
    def __init__(
        self, client: CacheClient, stats: Stats, publish_lock: threading.Lock
    ) -> None:
        self.client = client
        self.stats = stats
        self.publish_lock = publish_lock
        self.stop_event = threading.Event()
        self.thread = threading.Thread(
            target=self._loop, name="cache-uploader", daemon=True
        )

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join()

    def _loop(self) -> None:
        idle_intervals = 0
        while not self.stop_event.wait(60):
            try:
                uploaded = publish(
                    self.client,
                    self.stats,
                    self.publish_lock,
                    include_failure_state=False,
                )
                idle_intervals = 0 if uploaded else idle_intervals + 1
                if idle_intervals == 10:
                    log("… Builds are still running; no new paths are ready to publish")
                    idle_intervals = 0
            except Exception as exception:  # noqa: BLE001 - retry any periodic failure.
                warning(f"Incremental cache upload failed; retrying later: {exception}")


def evaluate_targets(client: CacheClient, stats: Stats) -> tuple[list[str], str]:
    with group("Evaluate cache targets"):
        BUILT_PATHS.write_text("")
        EVALUATION_PATHS.write_text("")
        UPLOADED_PATHS.write_text("")
        NEXT_FAILURES.write_text("")

        subprocess.run(
            [
                "nix",
                "eval",
                "--raw",
                ".#nixosConfigurations.default.config.system.build.toplevel.drvPath",
                "--no-update-lock-file",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        write_lines(EVALUATION_PATHS, {path for _, path in snapshot_built_records()})

        package_expression = (
            'n: builtins.map (p: "${p.drvPath}^${p.outputName}") '
            "(n.config.environment.systemPackages ++ "
            "builtins.concatMap (u: u.packages) (builtins.attrValues n.config.users.users) ++ "
            "n.config.services.udev.packages ++ n.config.boot.extraModulePackages ++ "
            "[ n.config.boot.kernelPackages.kernel ])"
        )
        candidates = sorted(
            set(
                json.loads(
                    run(
                        [
                            "nix",
                            "eval",
                            "--json",
                            ".#nixosConfigurations.default",
                            "--apply",
                            package_expression,
                            "--no-update-lock-file",
                        ]
                    ).stdout
                )
            )
        )
        kernel_drv = run(
            [
                "nix",
                "eval",
                "--raw",
                ".#nixosConfigurations.default.config.boot.kernelPackages.kernel.drvPath",
                "--no-update-lock-file",
            ]
        ).stdout.strip()

        plan = subprocess.run(
            [
                "nix",
                "build",
                "--dry-run",
                "--no-link",
                "--no-update-lock-file",
                *candidates,
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if plan.returncode:
            raise RuntimeError(f"Nix dry-run failed:\n{plan.stdout}")
        planned_drvs = {
            match.group(1)
            for line in plan.stdout.splitlines()
            if (match := re.match(r"^\s+(/nix/store/\S+\.drv)$", line))
        }
        needed = [
            target for target in candidates if target.split("^", 1)[0] in planned_drvs
        ]

        status, body = client.read("ci/failed-targets")
        if status == 200:
            previous_failures = set(body.decode().splitlines())
        elif status == 404:
            previous_failures = set()
        else:
            raise RuntimeError(f"failed-target state returned HTTP {status}")

        retry_failed = os.environ.get("RETRY_FAILED", "").lower() == "true"
        skipped = set() if retry_failed else set(needed) & previous_failures
        write_lines(NEXT_FAILURES, skipped)
        targets = [target for target in needed if target not in skipped]
        stats.missing = len(needed)
        stats.attempted = len(targets)
        log(f"• {len(needed)} derivations missing from configured substituters")
        log(f"• {len(skipped)} unchanged failures skipped")
        log(f"• {len(targets)} derivations queued with two parallel workers")
        return targets, kernel_drv


def target_name(target: str) -> str:
    name = Path(target.split("^", 1)[0]).name
    return name.split("-", 1)[1].removesuffix(".drv") if "-" in name else name


def build_one(target: str, kernel_drv: str) -> tuple[str, int, str]:
    limit = "120m" if target.split("^", 1)[0] == kernel_drv else "45m"
    log(f"• Building {target_name(target)} (timeout {limit})")
    result = subprocess.run(
        [
            "timeout",
            "--signal=TERM",
            "--kill-after=2m",
            limit,
            "nix",
            "build",
            "--no-link",
            "--no-update-lock-file",
            "--option",
            "max-jobs",
            "1",
            "--option",
            "cores",
            "2",
            "--log-format",
            "raw",
            target,
        ],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return target, result.returncode, result.stdout


def build_packages(targets: list[str], kernel_drv: str, stats: Stats) -> None:
    failures = read_lines(NEXT_FAILURES)
    if not targets:
        stats.failed = len(failures)
        return
    log(f"▶ Building {len(targets)} missing package derivations")
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {
            executor.submit(build_one, target, kernel_drv): target for target in targets
        }
        completed = 0
        for future in as_completed(futures):
            target, status, output = future.result()
            completed += 1
            name = target_name(target)
            if status == 0:
                stats.succeeded += 1
                log(f"✓ [{completed}/{len(targets)}] {name}")
                continue
            failures.add(target)
            warning(
                f"[{completed}/{len(targets)}] {name} failed with exit code {status}"
            )
            with group(f"Failed build log · {name}"):
                log(output.rstrip() or "(no build output)")
    write_lines(NEXT_FAILURES, failures)
    stats.failed = len(failures)


def build_system(stats: Stats) -> bool:
    log("▶ Building the complete NixOS system")
    status = subprocess.run(
        [
            "nix",
            "build",
            ".#nixosConfigurations.default.config.system.build.toplevel",
            "--no-link",
            "--no-update-lock-file",
            "--log-format",
            "raw",
        ],
        check=False,
    ).returncode
    stats.system = "passed" if status == 0 else "failed"
    if status == 0:
        log("✓ Complete NixOS system build passed")
    return status == 0


def run_pipeline() -> None:
    for name in ("NIX_CACHE_SIGNING_KEY", "NIX_CACHE_WRITE_TOKEN"):
        if not os.environ.get(name):
            raise RuntimeError(f"Missing {name} secret")

    for state_file in (BUILT_PATHS, EVALUATION_PATHS, UPLOADED_PATHS, NEXT_FAILURES):
        state_file.unlink(missing_ok=True)

    stats = Stats()
    client = CacheClient()
    publish_lock = threading.Lock()
    uploader = None
    failure_state_ready = False
    generation_ready = False
    lock_digest = ""
    pipeline_error = None
    final_upload_error = None
    try:
        lock_digest, generation_ready = ensure_generation(client, stats)
        with group("Configure Nix cache inputs"):
            configure_nix()
            log("✓ Loaded substituters and trusted keys from flake.nix")
        targets, kernel_drv = evaluate_targets(client, stats)
        uploader = IncrementalUploader(client, stats, publish_lock)
        uploader.start()
        build_packages(targets, kernel_drv, stats)
        failure_state_ready = True
        if not build_system(stats):
            raise RuntimeError("complete NixOS system build failed")
    except Exception as exception:  # noqa: BLE001 - final upload must run on any failure.
        pipeline_error = exception
    finally:
        if uploader is not None:
            uploader.stop()
        try:
            publish(
                client,
                stats,
                publish_lock,
                include_failure_state=failure_state_ready,
            )
        except Exception as exception:  # noqa: BLE001 - preserve the pipeline failure.
            final_upload_error = exception

        if pipeline_error is None and final_upload_error is None and generation_ready:
            try:
                client.upload_metadata(LOCK_DIGEST_KEY, lock_digest + "\n")
                log(f"✓ Published cache generation {lock_digest[:12]}")
            except Exception as exception:  # noqa: BLE001 - report metadata upload failures.
                final_upload_error = exception
        elif pipeline_error is None and final_upload_error is None:
            warning("Cache build succeeded, but its generation remains uncommitted")
        if pipeline_error is not None and final_upload_error is not None:
            warning(f"Final cache upload also failed: {final_upload_error}")
        stats.write_summary()
        client.close()

    if pipeline_error is not None:
        raise pipeline_error
    if final_upload_error is not None:
        raise final_upload_error


def main() -> int:
    if os.environ.get("DRV_PATH") and os.environ.get("OUT_PATHS"):
        record_built_paths()
        return 0
    try:
        run_pipeline()
    except Exception as exception:  # noqa: BLE001 - render a concise CI annotation.
        error(str(exception))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
