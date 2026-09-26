{ pkgs, utils, ... }:

let
  xbvr = pkgs.callPackage ../local-packages/xbvr.nix { };

  launcher = pkgs.writeShellApplication {
    name = "xbvr";
    runtimeInputs = [ pkgs.ffmpeg ];
    text = ''
      exec ${xbvr}/bin/xbvr "$@"
    '';
  };

  package = pkgs.symlinkJoin {
    name = "xbvr-${xbvr.version}";
    paths = [ launcher ];
    meta = xbvr.meta // {
      mainProgram = "xbvr";
    };
  };
in
utils.mkSandboxed {
  inherit package;
  name = "xbvr";
  displayName = "XBVR";
  configDir = "xbvr";
  exportDesktopFiles = false;
  presets = [ "network" ];
  homeBinds = {
    ro = [
      { suffix = "/Downloads"; }
      { suffix = "/Local"; }
    ];
  };
  extraPerms = {
    bubblewrap.env.SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
  };
}
