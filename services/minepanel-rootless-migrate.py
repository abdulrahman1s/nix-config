"""Copy MinePanel into a rootless account without modifying its original data."""

import json
import os
from pathlib import Path
import pwd
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def container_ids_to_stop(containers, state_dir):
    prefix = str(state_dir / "servers")
    names = {"minepanel-backend", "minepanel-frontend"}
    return [
        container["Id"]
        for container in containers
        if container["Name"].lstrip("/") in names
        or any(
            mount.get("Source") == prefix
            or mount.get("Source", "").startswith(prefix + "/")
            for mount in container.get("Mounts", [])
        )
    ]


def container_identity(config):
    uid = int(config.get("uid", 1000))
    gid = int(config.get("gid", 1000))
    if not (0 <= uid < 65536 and 0 <= gid < 65536):
        raise ValueError("Minecraft UID/GID exceeds the rootless subordinate range")
    return uid, gid


def main():
    state_dir = Path(os.environ["MINEPANEL_STATE_DIR"])
    destination = state_dir / "rootless"
    marker = state_dir / ".migrated-to-rootless-podman-v1"
    account = pwd.getpwnam("minepanel")
    # Refuse ancestor redirection before running privileged copy/chown operations.
    for path in [state_dir, destination, marker, state_dir / "servers", state_dir / "data"]:
        if path.is_symlink():
            raise RuntimeError(f"Refusing symlink at {path}")
    if marker.exists():
        if not destination.is_dir():
            raise RuntimeError("Rootless migration marker exists without its data")
        return
    if destination.exists():
        raise RuntimeError("Rootless data already exists without a marker; preserve it for review")

    # Disable old restart policies before stopping, so Docker cannot revive the
    # original world alongside the migrated copy on a later boot.
    ids = run("docker", "ps", "-aq", capture_output=True, text=True).stdout.split()
    if ids:
        containers = json.loads(run("docker", "inspect", *ids, capture_output=True, text=True).stdout)
        for container_id in container_ids_to_stop(containers, state_dir):
            run("docker", "update", "--restart=no", container_id, stdout=subprocess.DEVNULL)
            run("docker", "stop", "-t", "120", container_id, stdout=subprocess.DEVNULL)

    # Reflinks retain the original files and owners without duplicating worlds.
    # Failed attempts keep their staging tree for recovery rather than deleting it.
    staging = Path(tempfile.mkdtemp(prefix=".rootless-migration-", dir=state_dir))
    for name in ["servers", "data", "minepanel.env"]:
        run("cp", "-a", "--reflink=always", "--", str(state_dir / name), str(staging / name))
    for server in (staging / "servers").iterdir():
        if server.is_symlink():
            raise RuntimeError(f"Refusing symlinked server directory: {server.name}")
        if not server.is_dir():
            continue
        for filename in ["server.json", "docker-compose.yml", "docker-compose.yaml"]:
            path = server / filename
            if path.is_symlink():
                raise RuntimeError(f"Refusing symlinked server configuration: {server.name}/{filename}")
            if path.is_file():
                content = path.read_text()
                path.write_text(content.replace(str(state_dir / "servers"), str(destination / "servers")))
    run("chown", "-hR", f"{account.pw_uid}:{account.pw_gid}", "--", str(staging))

    unshare = [
        "runuser", "-u", "minepanel", "--", "env",
        f"HOME={os.environ['MINEPANEL_PODMAN_HOME']}",
        f"XDG_RUNTIME_DIR={os.environ['MINEPANEL_RUNTIME_DIR']}",
        os.environ["MINEPANEL_PODMAN"], "unshare", "chown", "-hR",
    ]
    # Java's container entrypoint runs as root inside its user namespace and
    # then drops to the configured UID. Translate only the copied runtime data.
    for server in (staging / "servers").iterdir():
        config_file = server / "server.json"
        if not server.is_dir() or not config_file.is_file():
            continue
        uid, gid = container_identity(json.loads(config_file.read_text()))
        for name in ["mc-data", "modpacks", "worlds", "backups"]:
            path = server / name
            if path.is_symlink():
                raise RuntimeError(f"Refusing symlinked runtime directory: {server.name}/{name}")
            if path.is_dir():
                run(*unshare, f"{uid}:{gid}", "--", str(path))
    shared_worlds = staging / "servers/.world/worlds"
    if shared_worlds.is_symlink():
        raise RuntimeError("Refusing symlinked global world library")
    if shared_worlds.is_dir():
        run(*unshare, "1000:1000", "--", str(shared_worlds))

    # Keep the desktop's minecraft-backups shortcut useful without giving its
    # account access to the panel database, socket, or writable runtime data.
    login_user = os.environ["MINEPANEL_LOGIN_USER"]
    servers = staging / "servers"
    run("setfacl", "-m", f"u:{login_user}:--x", "--", str(staging), str(servers))
    for server in servers.iterdir():
        backups = server / "backups"
        if server.is_dir() and backups.is_dir() and not backups.is_symlink():
            run("setfacl", "-m", f"u:{login_user}:--x", "--", str(server))
            run("setfacl", "-R", "-m", f"u:{login_user}:rX", "--", str(backups))
            for directory in [backups, *(p for p in backups.rglob('*') if p.is_dir() and not p.is_symlink())]:
                run("setfacl", "-d", "-m", f"u:{login_user}:r-x", "--", str(directory))

    staging.rename(destination)
    marker.touch(mode=0o600)
    print("MinePanel rootless copy is ready; original data and stopped Docker containers were retained.")


if __name__ == "__main__":
    main()
