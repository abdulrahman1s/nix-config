{ pkgs, inputs, username, ... }:

let
  nixpak = inputs.nixpak;
  utils = import ./nixpak { inherit pkgs nixpak username; };
  sandboxedXdgUtils = pkgs.callPackage ./nixpak/xdg-utils.nix { };
  call = file: import file { inherit pkgs utils sandboxedXdgUtils inputs username; };

  mpv = call ./mpv.nix;
  minecraft = call ./minecraft.nix;
  umu-launcher = call ./umu-launcher.nix;
  umu-launcher-offline = call ./umu-launcher-offline.nix;
  browser = call ./browser.nix;
  orca-slicer = call ./orca-slicer.nix;
in
{
  imports = [ browser.module ];

  users.users.${username}.packages = [
    mpv
    umu-launcher
    umu-launcher-offline
    minecraft
    orca-slicer
  ] ++ browser.packages;
}
