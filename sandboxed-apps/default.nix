{ pkgs, inputs, username, config, ... }:

let
  nixpak = inputs.nixpak;
  utils = import ./nixpak { inherit pkgs nixpak username; };
  sandboxedXdgUtils = pkgs.callPackage ./nixpak/xdg-utils.nix { };
  call = file: import file { inherit pkgs utils sandboxedXdgUtils inputs username config; };

  mpv = call ./mpv.nix;
  minecraft = call ./minecraft.nix;
  umu-launcher = call ./umu-launcher.nix;
  umu-launcher-offline = call ./umu-launcher-offline.nix;
  browser = call ./browser.nix;
  orca-slicer = call ./orca-slicer.nix;
  stremio = call ./stremio.nix;
  wireview = call ./wireview-linux.nix;
  photocraft = call ./photocraft.nix;
  filmcraft = call ./filmcraft.nix;
in
{
  imports = [ browser.module ];

  xdg.mime.defaultApplications = {
    "x-scheme-handler/stremio" = "com.sandboxed.stremio.desktop";
  };

  system.userActivationScripts.stremio-data.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 \
      "$HOME/.config/stremio-web" \
      "$HOME/.cache/stremio-web" \
      "$HOME/.pki/nssdb" \
      "$HOME/.stremio-server"

    if [ ! -e "$HOME/Downloads" ]; then
      ${pkgs.coreutils}/bin/install -d -m 0755 "$HOME/Downloads"
    fi
  '';


  system.userActivationScripts.photocraft-data.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 "$HOME/.config/photocraft"
  '';

  system.userActivationScripts.filmcraft-data.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 "$HOME/.config/filmcraft"
  '';

  system.userActivationScripts.sklauncher-data.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 "$HOME/.config/sklauncher"
  '';


  users.users.${username}.packages = [
    mpv
    umu-launcher
    umu-launcher-offline
    minecraft
    orca-slicer
    stremio
    wireview.sandbox
    photocraft
    filmcraft
  ] ++ browser.packages;

  services.udev.packages = [ wireview.package ];
}
