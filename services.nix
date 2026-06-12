{ config, pkgs, username, ... }:

let
  hardening = import ./system/hardening.nix;
  cloudflareTunnelToken = config.age.secrets.cloudflare-tunnel-token.path;
  rcloneConfig = config.age.secrets.rclone-config.path;
  dokployDbPassword = config.age.secrets.dokploy-db-password.path;
  dokployAuthSecret = config.age.secrets.dokploy-auth-secret.path;

  slim = pkgs.stdenv.mkDerivation {
    pname = "slim";
    version = "0.8.0";
    src = pkgs.fetchurl {
      url = "https://github.com/kamranahmedse/slim/releases/download/0.9.1/slim_0.9.1_linux_amd64.tar.gz";
      hash = "sha256-1VuZuYinnNPR8AEKDZfujaKLbRJjYqi7YcwF896Qr4s=";
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    installPhase = ''
      mkdir -p $out/bin
      cp slim $out/bin/slim
    '';
  };

  slimServices = [
    { domain = "homeassistant"; port = 8123; }
    { domain = "homebridge"; port = 8581; }
    { domain = "logging"; port = 7777; }
    { domain = "radio"; port = 4444; }
    { domain = "dokploy"; port = 3000; }
  ];

  slimConfigFile = (pkgs.formats.yaml { }).generate "slim-config.yaml" {
    services = map (s: { inherit (s) domain port; } // (if s ? path then { inherit (s) path; } else { })) slimServices;
    log_mode = "minimal";
    cors = false;
  };
in

{
  age.secrets = {
    cloudflare-tunnel-token.file = ./secrets/cloudflare-tunnel-token.age;
    rclone-config.file = ./secrets/rclone.conf.age;
    dokploy-db-password.file = ./secrets/dokploy-db-password.age;
    dokploy-auth-secret.file = ./secrets/dokploy-auth-secret.age;
  };

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


  # ── Rclone – Encrypted Cloud Sync ─────────────────────────
  systemd.services.rclone-watcher = {
    description = "Real-time Sync Watcher for Rclone";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = rcloneConfig;
    environment = {
      RCLONE_S3_NO_CHECK_BUCKET = "true";
    };
    serviceConfig = {
      Type = "simple";
      User = username;
      LoadCredential = "rclone.conf:${rcloneConfig}";
      ExecStart = pkgs.writeScript "rclone-watcher-script" ''
        #!${pkgs.bash}/bin/bash
        SOURCE="/home/${username}/Cloud"
        REMOTE="my-vault:live"
        BACKUP="my-vault:trash/$(date +%Y-%m-%d)"
        CONFIG="$CREDENTIALS_DIRECTORY/rclone.conf"

        # Initial sync on boot
        ${pkgs.rclone}/bin/rclone sync "$SOURCE" "$REMOTE" \
          --config="$CONFIG" --backup-dir="$BACKUP" \
          --suffix=_deleted --s3-no-check-bucket

        # Watch for changes and sync (debounced with 2s sleep)
        ${pkgs.inotify-tools}/bin/inotifywait -m -r -e modify,create,delete,move "$SOURCE" \
          | while read path action file; do
              echo "Event detected: $file via $action. Syncing..."
              sleep 2
              ${pkgs.rclone}/bin/rclone sync "$SOURCE" "$REMOTE" \
                --config="$CONFIG" --backup-dir="$BACKUP" \
                --suffix=_deleted --s3-no-check-bucket
            done
      '';
      Restart = "always";
      RestartSec = "10";
    };
  };


  # ── Avahi / mDNS ──────────────────────────────────────────
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
      userServices = true;
    };
  };


  virtualisation.docker.enable = true;
  virtualisation.docker.daemon.settings.live-restore = false;
  virtualisation.docker.daemon.settings.dns = [ "1.1.1.1" "9.9.9.9" ];
  # Keep BuildKit caches until they are explicitly pruned; large CUDA base images
  # are expensive to re-download after automatic disk-pressure GC.
  virtualisation.docker.daemon.settings.builder.gc.enabled = false;
  services.dokploy.enable = true;
  # services.dokploy.port = null;
  services.dokploy.hostPortMode = true;

  services.dokploy.database.passwordFile = dokployDbPassword;
  services.dokploy.auth.secretFile = dokployAuthSecret;


  # ── Slim – Local HTTPS Dev Proxy ──────────────────────────
  # To add/remove proxied services, edit slimServices in the top-level let block.
  environment.systemPackages = [ slim ];

  # Pre-populate /etc/hosts with # slim markers so slim never needs to write it
  # (NixOS is read-only; generated from slimServices automatically).
  networking.extraHosts = builtins.concatStringsSep "\n"
    (map (s: "127.0.0.1 ${s.domain}.test # slim") slimServices);

  systemd.services.slim = {
    description = "Slim local HTTPS proxy daemon";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      User = username;
      PIDFile = "/home/${username}/.slim/slim.pid";
      ExecStart = "${slim}/bin/slim up --config ${slimConfigFile}";
      ExecStop = "${slim}/bin/slim down --config ${slimConfigFile}";
      ExecStartPost =
        let
          natUp = pkgs.writeScript "slim-nat-up" ''
            #!${pkgs.bash}/bin/bash
            IPT="${pkgs.iptables}/bin/iptables"
            # Create SLIM chain (ignore error if already exists)
            $IPT -t nat -N SLIM 2>/dev/null || true
            # Add redirect rules into the SLIM chain
            $IPT -t nat -C SLIM -p tcp -d 127.0.0.1/32 --dport 80 -j REDIRECT --to-ports 10080 2>/dev/null \
              || $IPT -t nat -A SLIM -p tcp -d 127.0.0.1/32 --dport 80 -j REDIRECT --to-ports 10080
            $IPT -t nat -C SLIM -p tcp -d 127.0.0.1/32 --dport 443 -j REDIRECT --to-ports 10443 2>/dev/null \
              || $IPT -t nat -A SLIM -p tcp -d 127.0.0.1/32 --dport 443 -j REDIRECT --to-ports 10443
            # Jump from OUTPUT into SLIM (on loopback, matching slim's doctor check)
            $IPT -t nat -C OUTPUT -o lo -p tcp -j SLIM 2>/dev/null \
              || $IPT -t nat -I OUTPUT 1 -o lo -p tcp -j SLIM
          '';
        in
        "+${natUp}";
      ExecStopPost =
        let
          natDown = pkgs.writeScript "slim-nat-down" ''
            #!${pkgs.bash}/bin/bash
            IPT="${pkgs.iptables}/bin/iptables"
            $IPT -t nat -D OUTPUT -o lo -p tcp -j SLIM 2>/dev/null || true
            $IPT -t nat -F SLIM 2>/dev/null || true
            $IPT -t nat -X SLIM 2>/dev/null || true
          '';
        in
        "+${natDown}";
      Restart = "on-failure";
      RestartSec = "5";
      AmbientCapabilities = "CAP_NET_BIND_SERVICE";
      CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
    } // hardening // {
      # Hardening (service-specific; shared baseline in system/hardening.nix)
      ProtectHome = "read-only"; # home dirs read-only …
      ReadWritePaths = [ "/home/${username}/.slim" ]; # … except slim's state dir
      RestrictRealtime = true; # no real-time scheduling
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  security.pki.certificateFiles = [ ./slim-ca.pem ];
}
