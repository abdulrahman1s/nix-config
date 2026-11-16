{ pkgs, utils, ... }:

utils.mkSandboxed {
  package = pkgs.callPackage ../local-packages/anydesk.nix { };
  name = "anydesk";
  displayName = "AnyDesk";
  wmClass = "Anydesk";
  # Xwayland permits outgoing sessions; AnyDesk cannot share a niri desktop.
  presets = [
    "network"
    "x11"
    "gpu"
    "audio"
    "notifications"
    "systray"
  ];

  homeBinds.rw = [
    # AnyDesk uses ~/.anydesk rather than XDG_CONFIG_HOME; already persisted.
    { suffix = "/.anydesk"; }
    { suffix = "/Downloads"; }
  ];

  extraPerms = {
    bubblewrap.env = {
      # The niri session sets Wayland toolkit defaults; AnyDesk needs Xwayland.
      GDK_BACKEND = "x11";
      QT_QPA_PLATFORM = "xcb";
    };
  };
}
