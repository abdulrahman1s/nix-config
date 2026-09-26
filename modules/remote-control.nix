{ config, pkgs, inputs, username, lanAddress, ... }:

let
  hardening = import ../system/hardening.nix;
  tokenPath = "/etc/remote-control.token";
  runtimeDirectory = "remote-control";
  runtimeDirectoryPath = "/run/${runtimeDirectory}";
  noctalia = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.noctalia;
  niriPackage = config.programs.niri.package;
  server = pkgs.writeText "remote-control-server.py" (
    builtins.replaceStrings
      [ "@username@" "@lanAddress@" "@wlClipboard@" "@niri@" "@noctalia@" "@runtimeDirectoryPath@" ]
      [ username lanAddress "${pkgs.wl-clipboard}" "${niriPackage}" "${noctalia}" runtimeDirectoryPath ]
      (builtins.readFile ./remote-control-server.py)
  );
in
{
  # Auto-generate an authorization token on first boot
  system.activationScripts.remote-control-token = ''
    if [ ! -f ${tokenPath} ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${tokenPath}
      echo "remote-control: generated new token at ${tokenPath}"
    fi
    ${pkgs.coreutils}/bin/chown ${username}:users ${tokenPath}
    ${pkgs.coreutils}/bin/chmod 0400 ${tokenPath}
  '';

  # These actions remain explicit and narrow; the HTTP service itself runs
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

  # ── HTTP server service ─────────────────────────────────
  systemd.services.remote-control = {
    description = "Remote session control HTTP server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = username;
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${server}";
      LoadCredential = "token:${tokenPath}";
      RuntimeDirectory = runtimeDirectory;
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
