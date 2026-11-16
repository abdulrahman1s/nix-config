#!/usr/bin/env python3
"""Keep S4MP's preparation intact and hand its game launch to native Steam."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import signal
import struct
import subprocess
import sys
import time

PACKAGE = Path(os.environ["S4MP_PACKAGE_DIR"])
ROOT = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "s4mp/2026.11.0"
PREFIX = Path(os.environ["S4MP_WINEPREFIX"])
APPDATA = PREFIX / "drive_c/users/steamuser/AppData"
STATE = APPDATA / "Local/com.s4mp.launcher/steam-start"
EXE = "s4mp-online-launcher-2026.11.0.exe"
ORIGINAL_NAME = b"modresourcesGameBinTS4_x64.exe"
BRIDGE_NAME = b"modresourcesGameBinS4MPgo_.exe"
OLD_BRIDGE_SHA256 = "fb625287e4b3c9e9a5748ad8f8cfe1ac4bb9ff471b6f734f5fd437e155a62def"
PROTONTRICKS_LAUNCH = os.environ["S4MP_PROTONTRICKS_LAUNCH"]
STEAM = os.environ["S4MP_STEAM"]


def configure_webview(output):
    # Keep Wine's working software window mode. The packaged stylesheet honors
    # reduced motion for the costly decorative backgrounds, not loading icons.
    # Scope these settings to S4MP; other apps in the Sims prefix keep theirs.
    # Xwayland does not supply the 4K display's 2x scale to WebView2 in Wine.
    arguments = ("--disable-gpu --force-prefers-reduced-motion=reduce "
                 "--force-device-scale-factor=2")
    subprocess.run([
        PROTONTRICKS_LAUNCH, "--appid", "1222670",
        r"C:\windows\system32\reg.exe", "add",
        r"HKLM\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments",
        "/v", EXE, "/t", "REG_SZ", "/d", arguments, "/f",
    ], check=True, stdout=output, stderr=output)


def install_bridge():
    source = (PACKAGE / EXE).read_bytes()
    expected = (PACKAGE / EXE).with_suffix(".sha256").read_text().strip()
    if hashlib.sha256(source).hexdigest() != expected:
        raise RuntimeError("Launcher version changed; review its Steam bridge before updating")
    if source.count(ORIGINAL_NAME) != 1 or len(ORIGINAL_NAME) != len(BRIDGE_NAME):
        raise RuntimeError("Launcher changed; review the Steam bridge before updating it")
    settings = json.loads((APPDATA / "Roaming/com.s4mp.launcher/launcher-settings.json").read_text())
    windows_path = PureWindowsPath(settings["installPath"])
    if not windows_path.drive or windows_path.drive.startswith("\\\\"):
        raise RuntimeError("Expected a mapped Windows drive for the Sims installation")
    drive = (PREFIX / "dosdevices" / windows_path.drive.lower()).resolve(strict=True)
    game = drive.joinpath(*windows_path.parts[1:])
    if not (game / "Game/Bin/TS4_x64.exe").is_file():
        raise RuntimeError("The original Sims executable was not found")
    bridge_source = PACKAGE / "S4MPgo_.exe"
    bridge_target = game / "Game/Bin/S4MPgo_.exe"
    contents = bridge_source.read_bytes()
    if bridge_target.exists() and bridge_target.read_bytes() != contents:
        previous = bridge_target.read_bytes()
        if hashlib.sha256(previous).hexdigest() != OLD_BRIDGE_SHA256:
            raise RuntimeError(f"Refusing to replace an unexpected file: {bridge_target}")
        backup = bridge_target.with_suffix(".exe.before-nixos")
        if backup.exists() and backup.read_bytes() != previous:
            raise RuntimeError(f"Refusing to replace an unexpected backup: {backup}")
        if not backup.exists():
            backup.write_bytes(previous)
        bridge_target.write_bytes(contents)
    elif not bridge_target.exists():
        bridge_target.write_bytes(contents)
        bridge_target.chmod(0o755)
    patched = source.replace(ORIGINAL_NAME, BRIDGE_NAME)
    destination = ROOT / EXE
    if not destination.exists() or destination.read_bytes() != patched:
        temporary = destination.with_suffix(".tmp")
        temporary.write_bytes(patched)
        temporary.chmod(0o755)
        temporary.replace(destination)
    print("Steam bridge ready; original launcher and game executables unchanged", flush=True)
    return destination


def read_arguments(data):
    if len(data) > 131072 or data[:4] != b"S4MP" or len(data) < 8:
        raise ValueError("Invalid Steam launch request")
    count, = struct.unpack_from("<I", data, 4)
    if count > 128:
        raise ValueError("Too many launch arguments")
    offset, args = 8, []
    for _ in range(count):
        size, = struct.unpack_from("<I", data, offset)
        offset += 4
        if size > 65536 or size % 2 or offset + size > len(data):
            raise ValueError("Invalid launch argument length")
        arg = data[offset:offset + size].decode("utf-16-le")
        if "\0" in arg:
            raise ValueError("Invalid launch argument")
        args.append(arg)
        offset += size
    if offset != len(data):
        raise ValueError("Trailing launch request data")
    return args


def serve(launcher=None):
    request = STATE / "request"
    last_launch = 0.0
    while launcher is None or launcher.poll() is None:
        if request.exists():
            try:
                args = read_arguments(request.read_bytes())
                if time.monotonic() - last_launch > 3:
                    # This is the host process environment, outside Proton's container.
                    environment = {key: value for key, value in os.environ.items()
                                   if not key.startswith(("WINE", "PROTON", "STEAM_COMPAT"))
                                   and key not in ("SteamAppId", "SteamGameId", "SteamOverlayGameId")}
                    subprocess.Popen([STEAM, "-applaunch", "1222670", *args],
                                     env=environment, start_new_session=True)
                    last_launch = time.monotonic()
                    print(time.strftime("%Y-%m-%d %H:%M:%S"),
                          "S4MP Start Game handed to Steam", flush=True)
            except (OSError, ValueError, struct.error) as error:
                print(f"Steam launch request failed: {error}", flush=True)
            finally:
                request.unlink(missing_ok=True)
        time.sleep(0.1)
    return launcher.returncode if launcher is not None else 0


def main():
    # Both WebView2 and the account/settings data live on the persistent game
    # disk. Do not create an empty replacement prefix if that disk is absent.
    if not (PREFIX / "system.reg").is_file():
        raise RuntimeError(f"The existing Sims 4 Proton prefix is unavailable: {PREFIX}")
    webview = PREFIX / "drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
    if not webview.is_dir():
        raise RuntimeError("Install Microsoft's WebView2 runtime in the Sims 4 Proton prefix first")
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "runtime.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("The S4MP Steam launch helper is already running", flush=True)
            return 0
        executable = install_bridge()
        (STATE / "request").unlink(missing_ok=True)
        for log in [ROOT / "launcher.log", ROOT / "cursor-fallback.log"]:
            if log.exists() and log.stat().st_size > 8 * 1024 * 1024:
                log.replace(log.with_suffix(".log.previous"))
        with (ROOT / "launcher.log").open("ab") as output, \
                (ROOT / "cursor-fallback.log").open("ab") as cursor_output:
            configure_webview(output)
            launcher = subprocess.Popen([
                PROTONTRICKS_LAUNCH, "--appid", "1222670",
                str(executable), *sys.argv[1:]], cwd=ROOT, stdout=output, stderr=output)
            cursor = subprocess.Popen([sys.executable, str(PACKAGE / "cursor-fallback.py"), str(os.getpid())],
                                      stdout=cursor_output, stderr=cursor_output)
            def stop(signum, frame):
                launcher.terminate()
                raise SystemExit(128 + signum)
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            try:
                return serve(launcher)
            finally:
                with contextlib.suppress(ProcessLookupError):
                    cursor.terminate()


if __name__ == "__main__":
    raise SystemExit(main())
