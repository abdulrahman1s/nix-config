{ pkgs, utils, sandboxedXdgUtils, ... }:

utils.mkSandboxed {
  package = pkgs.discord;
  displayName = "Discord";
  name = "discord";
  configDir = "discord";
  resourceLimits = {
    mem = "2G";
    cpu = "200%";
  };
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
    "portals"
    "notifications"
    "systray"
  ];
  extraPerms =
    { sloth, ... }:
    {
      bubblewrap = {
        bind.rw = [
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
        env = {
          BROWSER = "xdg-open";
        };
      };
    };
}
