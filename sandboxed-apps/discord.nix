{ pkgs, utils, sandboxedXdgUtils, ... }:

utils.mkSandboxed {
  package = pkgs.callPackage ../local-packages/discord.nix { };
  name = "discord";
  executableName = "Discord";
  displayName = "Discord (Secure)";
  wmClass = "discord";
  configDir = "discord";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "network"
    "wayland"
    "gpu"
    "audio"
    "portals"
    "notifications"
    "systray"
  ];
  extraPerms = {
    # Host profile bins are hidden; Discord's module staging script needs these
    # tools, and browser links must go through the OpenURI portal.
    bubblewrap.env.PATH = pkgs.lib.makeBinPath [ pkgs.coreutils sandboxedXdgUtils ];
  };
}
