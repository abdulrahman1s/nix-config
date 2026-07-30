{ config, pkgs, inputs, username, lanAddress, ... }:

let
  hardening = import ../system/hardening.nix;
  tokenPath = "/etc/remote-control.token";
  stateDirectory = "remote-control";
  certificatePath = "/var/lib/${stateDirectory}/server.crt";
  privateKeyPath = "/var/lib/${stateDirectory}/server.key";
  runtimeDirectoryPath = "/run/${stateDirectory}";
  noctalia = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
  niriPackage = config.programs.niri.package;
  server = pkgs.writeText "remote-control-server.py" (
    builtins.replaceStrings
      [ "@username@" "@lanAddress@" "@wlClipboard@" "@niri@" "@noctalia@" "@certificatePath@" "@privateKeyPath@" "@runtimeDirectoryPath@" ]
      [ username lanAddress "${pkgs.wl-clipboard}" "${niriPackage}" "${noctalia}" certificatePath privateKeyPath runtimeDirectoryPath ]
      (builtins.readFile ./remote-control-server.py)
  );
  generateCertificate = pkgs.writeShellScript "remote-control-generate-certificate" ''
    set -euo pipefail
    umask 077

    if [ ! -s ${privateKeyPath} ] || [ ! -s ${certificatePath} ]; then
      key_tmp="${privateKeyPath}.tmp"
      cert_tmp="${certificatePath}.tmp"
      trap '${pkgs.coreutils}/bin/rm -f "$key_tmp" "$cert_tmp"' EXIT

      ${pkgs.openssl}/bin/openssl req \
        -x509 \
        -newkey rsa:3072 \
        -sha256 \
        -nodes \
        -days 3650 \
        -subj "/CN=${lanAddress}" \
        -addext "subjectAltName=IP:${lanAddress}" \
        -keyout "$key_tmp" \
        -out "$cert_tmp"

      ${pkgs.coreutils}/bin/mv "$key_tmp" ${privateKeyPath}
      ${pkgs.coreutils}/bin/mv "$cert_tmp" ${certificatePath}
      ${pkgs.coreutils}/bin/chmod 0600 ${privateKeyPath}
      ${pkgs.coreutils}/bin/chmod 0644 ${certificatePath}
    fi
  '';
in
{
  # Auto-generate a bearer token on first boot
  system.activationScripts.remote-control-token = ''
    if [ ! -f ${tokenPath} ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${tokenPath}
      echo "remote-control: generated new token at ${tokenPath}"
    fi
    ${pkgs.coreutils}/bin/chown ${username}:users ${tokenPath}
    ${pkgs.coreutils}/bin/chmod 0400 ${tokenPath}
  '';

  # These actions remain explicit and narrow; the HTTPS service itself runs
  # unprivileged and only asks logind for the two power operations it exposes.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      const remoteControlActions = [
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions"
      ];

      if (subject.user == "${username}" && remoteControlActions.indexOf(action.id) >= 0) {
        return polkit.Result.YES;
      }
    });
  '';

  # ── HTTPS server service ────────────────────────────────
  systemd.services.remote-control = {
    description = "Remote session control HTTPS server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = username;
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${server}";
      ExecStartPre = generateCertificate;
      LoadCredential = "token:${tokenPath}";
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0700";
      RuntimeDirectory = stateDirectory;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = "3";
    } // hardening // {
      ProtectHome = "read-only";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictSUIDSGID = true;
      CapabilityBoundingSet = "";
    };
  };
}
