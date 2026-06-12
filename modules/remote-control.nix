{ pkgs, inputs, username, lanAddress, ... }:

let
  tokenPath = "/etc/remote-control.token";
  noctalia-shell = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
  server = pkgs.writeText "remote-control-server.py" (
    builtins.replaceStrings
      [ "@tokenPath@" "@username@" "@lanAddress@" "@wlClipboard@" "@niri@" "@noctaliaShell@" ]
      [ tokenPath username lanAddress "${pkgs.wl-clipboard}" "${pkgs.niri}" "${noctalia-shell}" ]
      (builtins.readFile ./remote-control-server.py)
  );
in
{


  # Auto-generate a bearer token on first boot
  system.activationScripts.remote-control-token = ''
    if [ ! -f ${tokenPath} ]; then
      ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d '/+\n' > ${tokenPath}
      chmod 600 ${tokenPath}
      echo "remote-control: generated new token at ${tokenPath}"
    fi
  '';

  # ── HTTP server service ─────────────────────────────────
  systemd.services.remote-control = {
    description = "Remote session control HTTP server";
    after       = [ "network.target" ];
    wantedBy    = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart  = "${pkgs.python3}/bin/python3 ${server}";
      Restart    = "always";
      RestartSec = "3";
    };
  };
}
