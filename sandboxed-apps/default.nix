{ pkgs, inputs, username, ... }:

let
  nixpak = inputs.nixpak;
  utils = import ./nixpak { inherit pkgs nixpak username; };
  sandboxedXdgUtils = pkgs.callPackage ./nixpak/xdg-utils.nix { };
  call = file: import file { inherit pkgs utils sandboxedXdgUtils inputs username; };

  discord = call ./discord.nix;
  mpv = call ./mpv.nix;
  minecraft = call ./minecraft.nix;
  umu-launcher = call ./umu-launcher.nix;
  umu-launcher-offline = call ./umu-launcher-offline.nix;
  browser = call ./browser.nix;
in
{
  imports = [ browser.module ];

  users.users.${username}.packages = [
    discord
    mpv
    umu-launcher
    umu-launcher-offline
    minecraft
  ] ++ browser.packages;
}
