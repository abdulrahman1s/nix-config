{ inputs, pkgs, utils, ... }:

utils.mkSandboxed {
  package = inputs.self.packages.${pkgs.system}.photocraft;
  name = "photocraft";
  displayName = "PhotoCraft";
  icon = ./icons/adobe-photoshop.svg;
  wmClass = "ai.storyteller.photocraft";
  configDir = "photocraft";
  # Vicinae launches from $HOME; dir mode would try to bind the whole home.
  pathBinding = "file";
  presets = [ "wayland" "gpu" ];
  homeBinds.rw = map (suffix: { inherit suffix; }) [
    "/Pictures"
    "/Documents"
    "/Downloads"
  ];
  extraPerms = { sloth, ... }: {
    # PhotoCraft uses the file chooser and document portal for paths outside
    # its explicit home binds. Its optional control channel is not enabled.
    bubblewrap.network = false;
    # The session enables MangoHud globally; this sandbox cannot read the
    # host blacklist, so disable its Vulkan layer for PhotoCraft explicitly.
    bubblewrap.env.DISABLE_MANGOHUD = "1";
    bubblewrap.bind.rw = [ (sloth.concat' sloth.runtimeDir "/doc") ];
    dbus.policies = {
      "org.freedesktop.DBus" = "talk";
      "org.freedesktop.portal.Desktop" = "talk";
      "org.freedesktop.portal.Documents" = "talk";
    };
  };
}
