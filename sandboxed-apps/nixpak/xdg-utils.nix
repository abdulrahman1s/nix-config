{ pkgs, ... }:

let
  # NixOS' xdg-open handles local paths/file URIs with OpenFile (FD passing)
  # and external links with OpenURI when portal mode is enabled.
  mkSandboxedXdgUtils = pkgs.writeShellScriptBin "xdg-open" ''
    export NIXOS_XDG_OPEN_USE_PORTAL=1
    exec ${pkgs.xdg-utils}/bin/xdg-open "$@"
  '';
in
pkgs.symlinkJoin {
  name = "sandboxed-xdg-utils";
  paths = [
    mkSandboxedXdgUtils
    pkgs.xdg-utils
  ];
}
