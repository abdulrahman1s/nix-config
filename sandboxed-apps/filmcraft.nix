{ inputs, pkgs, utils, ... }:

utils.mkSandboxed {
  package = inputs.self.packages.${pkgs.system}.filmcraft;
  name = "filmcraft";
  displayName = "FilmCraft";
  icon = ./icons/adobe-premiere-pro.svg;
  wmClass = "ai.storyteller.filmcraft";
  configDir = "filmcraft";
  # Vicinae launches from $HOME; dir mode would try to bind the whole home.
  pathBinding = "file";
  presets = [ "wayland" "gpu" "audio" ];
  homeBinds.rw = map (suffix: { inherit suffix; }) [
    "/Pictures"
    "/Documents"
    "/Downloads"
  ];
  extraPerms = { sloth, ... }: {
    bubblewrap.network = false;
    bubblewrap.env.DISABLE_MANGOHUD = "1";
    bubblewrap.bind.rw = [ (sloth.concat' sloth.runtimeDir "/doc") ];
    dbus.policies = {
      "org.freedesktop.DBus" = "talk";
      "org.freedesktop.portal.Desktop" = "talk";
      "org.freedesktop.portal.Documents" = "talk";
    };
  };
}
