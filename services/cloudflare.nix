{ config, pkgs, username, lib, ... }:

let
  cloudflareTunnelToken = config.age.secrets.cloudflare-tunnel-token.path;
in

{
  options.services.cloudflare-warp-proxy.braveHosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "search.nixos.org" ];
    description = "Exact hostnames routed through the local WARP proxy by Brave.";
  };

  config = {
  age.secrets.cloudflare-tunnel-token.file = ../secrets/cloudflare-tunnel-token.age;

  # ── Cloudflare WARP ────────────────────────────────────────
  services.cloudflare-warp.enable = true;

  # WARP's registration is done once by the user. After that, keep the
  # daemon in local proxy mode so it does not change system-wide routing.
  systemd.services.cloudflare-warp-proxy = {
    description = "Configure Cloudflare WARP as a local proxy";
    wantedBy = [ "multi-user.target" ];
    requires = [ "cloudflare-warp.service" ];
    after = [ "cloudflare-warp.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      ExecStart = pkgs.writeShellScript "cloudflare-warp-proxy" ''
        set -eu

        for attempt in 1 2 3 4 5; do
          [ -S /run/cloudflare-warp/warp_service ] && break
          ${pkgs.coreutils}/bin/sleep 1
        done

        if ! ${pkgs.cloudflare-warp}/bin/warp-cli --accept-tos registration show >/dev/null 2>&1; then
          echo "WARP is not registered yet; run warp-cli registration new, then start this service."
          exit 0
        fi

        ${pkgs.cloudflare-warp}/bin/warp-cli --accept-tos tunnel protocol set MASQUE
        ${pkgs.cloudflare-warp}/bin/warp-cli --accept-tos proxy port 40000
        ${pkgs.cloudflare-warp}/bin/warp-cli --accept-tos mode proxy
        ${pkgs.cloudflare-warp}/bin/warp-cli --accept-tos connect
      '';
    };
  };

  # The first switch adds an impermanence bind mount over WARP's existing
  # state directory. Copy its contents beforehand without replacing any state
  # already present in /persist. Later activations see the bind mount and skip.
  system.activationScripts.cloudflare-warp-state-migration = {
    deps = [ "users" ];
    text = ''
      src=/var/lib/cloudflare-warp
      dst=/persist/var/lib/cloudflare-warp

      if [ -d "$src" ] && [ ! -L "$src" ] \
        && ! ${pkgs.util-linux}/bin/mountpoint -q "$src" \
        && [ -f "$src/warp.db" ] && [ ! -e "$dst/warp.db" ]; then
        if [ -L "$dst" ]; then
          echo "WARP state migration: refusing symlink at $dst" >&2
        else
          ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "$dst"
          ${pkgs.coreutils}/bin/cp -a -n "$src/." "$dst/"
        fi
      fi
    '';
  };

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
  };
}
