{ pkgs, utils, ... }:

let
  package = pkgs.callPackage ../local-packages/wireview-linux.nix { };
in
{
  inherit package;

  sandbox = utils.mkSandboxed {
    inherit package;
    name = "wireview-linux";
    displayName = "WireView Pro II";
    configDir = "PowerMonitor";
    presets = [
      "x11"
      "gpu"
      "usb"
      "portals"
      "notifications"
      "systray"
    ];
    homeBinds.rw = [
      { suffix = "/.local/share/PowerMonitor"; }
      { suffix = "/Downloads"; }
      { suffix = "/Documents"; }
    ];
    extraPerms = {
      # Avalonia owns org.kde.StatusNotifierItem-<pid>-<id>; xdg-dbus-proxy
      # only supports wildcards after a dot, so this app needs the KDE namespace.
      dbus.policies."org.kde.*" = "own";
      # SerialPort enumerates /dev/ttyACM*, while the USB preset covers DFU mode.
      bubblewrap.bind.dev = map (i: "/dev/ttyACM${toString i}") (pkgs.lib.range 0 9);
      bubblewrap.bind.ro = [ "/sys/class/tty" ];
      # The GUI uses the daemon socket for commands when hwmon is active.
      bubblewrap.bind.rw = [ "/run/wireviewd.sock" ];
    };
  };
}
