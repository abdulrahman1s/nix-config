{ pkgs, utils, sandboxedXdgUtils, ... }:

utils.mkSandboxed {
  package = pkgs.callPackage ../local-packages/digup.nix {
    xdg-utils = sandboxedXdgUtils;
  };
  name = "digup";
  displayName = "DigUp";
  wmClass = "digup-shell";
  configDir = "com.abdurrahim.DigUp";
  # Network is needed for the first-run model download from Hugging Face.
  presets = [ "network" "wayland" "gpu" "audio" "systray" ];
  homeBinds = {
    rw = map (suffix: { inherit suffix; }) [
      "/.local/share/digup"
      "/.local/share/com.abdurrahim.DigUp"
    ];
    # Index only these trees; never expose the whole home or credentials.
    ro = map (suffix: { inherit suffix; }) [
      "/Documents"
      "/Pictures"
      "/Downloads"
      "/Books"
      "/Inbox"
      "/projects"
    ];
  };
  extraPerms = { sloth, ... }: {
    bubblewrap.bind.rw = [ (sloth.concat' sloth.runtimeDir "/doc") ];
    dbus.policies = {
      "org.freedesktop.DBus" = "talk";
      "org.freedesktop.portal.Desktop" = "talk";
      "org.freedesktop.portal.Documents" = "talk";
    };
  };
}
