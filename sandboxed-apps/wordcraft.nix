{ pkgs, utils, ... }:

utils.mkSandboxed {
  package = pkgs.wordcraft;
  name = "wordcraft";
  displayName = "WordCraft";
  wmClass = "ai.storyteller.wordcraft";
  configDir = "wordcraft";
  pathBinding = "file";
  # winit supports file drag-and-drop on X11 only.
  presets = [ "x11" "gpu" "portals" ];
  homeBinds.rw = map (suffix: { inherit suffix; }) [
    "/Documents"
    "/Downloads"
    "/Pictures"
  ];
  extraPerms = {
    bubblewrap.network = false;
    bubblewrap.env = {
      WAYLAND_DISPLAY = "";
      # The global MangoHud layer cannot read its host blacklist in the sandbox.
      DISABLE_MANGOHUD = "1";
    };
  };
}
