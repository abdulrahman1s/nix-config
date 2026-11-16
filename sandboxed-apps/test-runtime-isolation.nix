{ pkgs, nixpak }:
let
  helpers = import ./nixpak { inherit pkgs nixpak; };
  probe = pkgs.writeShellScriptBin "sandbox-isolation-probe" ''
    exec ${pkgs.python3}/bin/python3 - "$@" <<'PY'
    import os
    from pathlib import Path
    import subprocess
    import ssl
    import sys

    assert 'SANDBOX_AUDIT_TOKEN' not in os.environ, 'Inherited shell secret exposed'
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    for path in [runtime / 'bus', runtime / 'systemd/private', runtime / 'security-audit-sentinel']:
        assert not path.exists(), f'Host runtime path exposed: {path}'
    proxy = runtime / 'nixpak-bus'
    assert proxy.is_socket(), 'Filtered session bus is unavailable'
    assert os.environ.get('HOME') and os.environ.get('PATH'), 'Application environment is incomplete'
    assert ssl.create_default_context().get_ca_certs(), 'TLS trust store is unavailable'
    if '--bluetooth' in sys.argv:
        system_bus = Path('/run/dbus/system_bus_socket')
        assert system_bus.is_socket(), 'Filtered system bus is unavailable'
        command = ['${pkgs.systemd}/bin/busctl', '--address=unix:path=' + str(system_bus)]
        forbidden = subprocess.run(command + ['get-property', 'org.freedesktop.systemd1',
            '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager', 'Version'], capture_output=True)
        assert forbidden.returncode != 0, 'System service manager exposed through BlueZ proxy'
        bluez = subprocess.run(command + ['call', 'org.bluez', '/', 'org.freedesktop.DBus.Peer', 'Ping'], capture_output=True)
        assert bluez.returncode == 0, 'BlueZ is unavailable through its proxy'
    else:
        assert not Path('/run/dbus/system_bus_socket').exists(), 'Raw system bus exposed'
        # A mounted socket is insufficient if the environment makes libpulse
        # reject the server address before it attempts to connect.
        pulse = subprocess.run(['${pkgs.pulseaudio}/bin/pactl', 'info'],
            capture_output=True, text=True, timeout=10)
        assert pulse.returncode == 0, 'PulseAudio connection failed: ' + pulse.stderr
        command = ['${pkgs.systemd}/bin/busctl', '--address=unix:path=' + str(proxy)]
        portal = subprocess.run(command + ['get-property', 'org.freedesktop.portal.Desktop',
            '/org/freedesktop/portal/desktop', 'org.freedesktop.portal.Settings', 'version'], capture_output=True)
        assert portal.returncode == 0, 'Desktop portal is unavailable'
        gvfs = subprocess.run(command + ['call', 'org.gtk.vfs.Daemon',
            '/org/gtk/vfs/Daemon', 'org.freedesktop.DBus.Peer', 'Ping'], capture_output=True)
        assert gvfs.returncode != 0, 'Host GVFS daemon is exposed'
    print('Runtime isolation probe passed')
    PY
  '';
  sandbox = helpers.mkSandboxed {
    package = probe;
    name = "sandbox-isolation-probe";
    exportDesktopFiles = false;
    presets = [ "wayland" "audio" "controller" "portals" ];
  };
  bluetooth = helpers.mkSandboxed {
    package = probe;
    name = "sandbox-bluetooth-probe";
    executableName = "sandbox-isolation-probe";
    exportDesktopFiles = false;
    presets = [ "bluetooth" ];
  };
in
pkgs.runCommand "sandbox-runtime-isolation-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${pkgs.python3}/bin/python3 - ${sandbox}/bin/sandbox-isolation-probe <<'PY'
  import json
  from pathlib import Path
  import sys

  launcher = Path(sys.argv[1]).resolve()
  config = json.loads(Path(launcher.read_text().splitlines()[1]).read_text())
  args = json.loads(Path(config['bwrap']['args']).read_text())
  # These are source paths, not merely environment-variable defaults.
  assert '/run/dbus' not in args, 'Raw system bus directory is mounted'
  assert '/run/dbus/system_bus_socket' not in args, 'Raw system bus socket is mounted'
  assert {'type': 'env', 'key': 'XDG_RUNTIME_DIR'} not in args, 'Whole runtime directory is mounted'
  assert '/dev/uinput' not in args, 'Input injection device is mounted'
  assert args.count('/dev/input') == 1, 'Host input tree is mounted as a source'
  assert '/dev/sandbox-input' in args, 'Controller-only device tree is missing'
  assert '--clearenv' in args, 'Applications inherit the host environment'
  proxy_args = Path(config['dbusProxy']['args']).read_text()
  assert '--talk=org.freedesktop.portal.Desktop' in proxy_args
  assert '--talk=org.freedesktop.portal.Documents' in proxy_args
  assert '--talk=org.freedesktop.portal.*' not in proxy_args, 'Portal namespace is unrestricted'
  assert 'org.gtk.vfs' not in proxy_args, 'Host GVfs is exposed'
  PY
  mkdir -p "$out/bin"
  ln -s ${sandbox}/bin/sandbox-isolation-probe "$out/bin/sandbox-isolation-probe"
  ln -s ${bluetooth}/bin/sandbox-bluetooth-probe "$out/bin/sandbox-bluetooth-probe"
''
