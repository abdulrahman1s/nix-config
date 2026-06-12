{ config, pkgs, ... }:

let
  cloudflareTunnelToken = config.age.secrets.cloudflare-tunnel-token.path;
in

{
  age.secrets.cloudflare-tunnel-token.file = ../secrets/cloudflare-tunnel-token.age;

  # ── Cloudflare WARP ────────────────────────────────────────
  services.cloudflare-warp.enable = false;

  users.users.cloudflared = {
    group = "cloudflared";
    isSystemUser = true;
  };

  users.groups.cloudflared = { };

  systemd.services.tunnel = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "systemd-resolved.service" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = cloudflareTunnelToken;
    serviceConfig = {
      LoadCredential = "tunnel-token:${cloudflareTunnelToken}";
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token-file %d/tunnel-token";
      Restart = "always";
      User = "cloudflared";
      Group = "cloudflared";
    };
  };
}
