{ pkgs, utils, ... }:

utils.mkSandboxed {
  package = pkgs.mpv;
  name = "mpv";
  pathBinding = "file";
  resourceLimits = {
    cpu = "200%";
    mem = "4G";
  };
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      # Static fallbacks for drag-and-drop into an already-running mpv (where
      # mpv gets the path internally, not as a launch arg). For terminal /
      # file-manager launches, pathBinding narrows to the actual file's dir.
      bubblewrap.bind.ro = [
        (sloth.concat' sloth.homeDir "/Videos")
        (sloth.concat' sloth.homeDir "/Music")
        (sloth.concat' sloth.homeDir "/Downloads")
      ];
    };
}
