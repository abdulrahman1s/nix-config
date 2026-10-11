#!/usr/bin/env python3
"""Write selected store paths to a binary cache without copying their closures."""

import json
from pathlib import Path
import subprocess
import sys


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def main():
    paths_file = Path(sys.argv[1])
    cache = Path(sys.argv[2])
    signing_key = Path(sys.argv[3])
    paths = sorted(set(paths_file.read_text().splitlines()))
    if not paths:
        return

    cache.joinpath("nar").mkdir(parents=True, exist_ok=True)
    cache.joinpath("nix-cache-info").write_text(
        "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n"
    )

    key_name = signing_key.read_text().split(":", 1)[0]
    run(
        ["nix", "store", "sign", "--key-file", str(signing_key), "--stdin"],
        input="".join(f"{path}\n" for path in paths),
        text=True,
    )
    info = json.loads(
        run(
            ["nix", "path-info", "--json", "--json-format", "1", *paths],
            capture_output=True,
            text=True,
        ).stdout
    )

    for path in paths:
        path_info = info[path]
        temporary_nar = cache / "nar" / f"{Path(path).name}.nar.zst"
        with subprocess.Popen(
            ["nix", "store", "dump-path", path], stdout=subprocess.PIPE
        ) as dump:
            run(
                ["zstd", "--quiet", "-T1", "-3", "-o", str(temporary_nar)],
                stdin=dump.stdout,
            )
            if dump.wait() != 0:
                raise RuntimeError(f"failed to dump {path}")

        file_hash = run(
            ["nix", "hash", "file", "--type", "sha256", "--base32", str(temporary_nar)],
            capture_output=True,
            text=True,
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


if __name__ == "__main__":
    main()
