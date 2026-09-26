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
  stremio = call ./stremio.nix;
  xbvr = call ./xbvr.nix;
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

  system.userActivationScripts.xbvr-data.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 "$HOME/.config/xbvr"

    # Older XBVR launches downloaded private codec copies here. The source
    # build now uses Nix's ffmpeg directly, so discard that stale mutable state.
    ${pkgs.coreutils}/bin/rm -f \
      "$HOME/.config/xbvr/bin/ffmpeg" \
      "$HOME/.config/xbvr/bin/ffprobe"
  '';

  systemd.user.services.xbvr = {
    description = "Sandboxed XBVR media server";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${xbvr}/bin/xbvr";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  users.users.${username}.packages = [
    mpv
    umu-launcher
    umu-launcher-offline
    minecraft
    orca-slicer
    stremio
    xbvr
  ] ++ browser.packages;
}
