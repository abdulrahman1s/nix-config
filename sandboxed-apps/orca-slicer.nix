{ pkgs, utils, sandboxedXdgUtils, ... }:

utils.mkSandboxed {
  package = pkgs.orca-slicer;
  name = "orca-slicer";
  displayName = "OrcaSlicer";
  configDir = "OrcaSlicer";
  pathBinding = "dir";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "network"
    "discovery"
    "portals"
    "secrets"
  ];
  homeBinds.rw = [
    { suffix = "/Downloads"; }
  ];
}
