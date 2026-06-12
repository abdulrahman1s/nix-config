{ config, pkgs, username, ... }:

let
  hardening = import ../system/hardening.nix;
  juicefsEnv = config.age.secrets.juicefs-env.path;
  juicefsMetaDb = "/var/lib/juicefs/cloud.db";
  juicefsMetaUrl = "sqlite3://${juicefsMetaDb}";
  juicefsMountPoint = "/mnt/Cloud";
  juicefsBucket = "https://08d5d1a99ebeef89f5623b9b3217a909.r2.cloudflarestorage.com/cloud-storage";
  juicefsR2Endpoint = "https://08d5d1a99ebeef89f5623b9b3217a909.r2.cloudflarestorage.com";
in

{
  age.secrets = {
    juicefs-env.file = ../secrets/juicefs-env.age;
    juicefs-rsa-key = {
      file = ../secrets/juicefs-rsa-key.pem.age;
      # juicefs-nix reads the key directly as the mount user at format time.
      owner = username;
    };
  };

  # The juicefs-nix module creates the mount point and cache dir, but not the
  # metadata engine's directory, where the SQLite db lives.
  systemd.tmpfiles.rules = [
    "d /var/lib/juicefs 0700 ${username} users - -"
  ];

  # ── JuiceFS – Encrypted Cloud Filesystem ──────────────────
  # Formats on first boot (idempotent via `juicefs status`) and mounts the volume.
  services.juicefs.mounts.cloud = {
    metaUrl = juicefsMetaUrl;
    mountPoint = juicefsMountPoint;
    user = username;
    group = "users";

    autoFormat = true;
    format = {
      name = "juicefs-cloud";
      storage = "s3";
      bucket = juicefsBucket;
      trashDays = 30;
      extraOptions = [ "--enable-acl" ];
    };

    encryption = {
      enable = true;
      rsaKeyFile = config.age.secrets.juicefs-rsa-key.path;
      # The RSA key has no passphrase, so none is needed at mount time.
    };

    cacheDir = "/var/cache/juicefs";
    cacheSize = 10240;
    backupMeta = "0";
    mountOptions = [
      "--buffer-size"
      "128"
      "--check-storage"
      "--enable-xattr"
      "--no-usage-report"
      "-o"
      "allow_other"
    ];

    environmentFile = juicefsEnv;
  };

  systemd.services.juicefs-metadata-backup = {
    description = "Back up JuiceFS SQLite metadata to Cloudflare R2";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = juicefsMetaDb;
    serviceConfig = {
      Type = "oneshot";
      User = username;
      StateDirectory = "juicefs";
      StateDirectoryMode = "0700";
      RuntimeDirectory = "juicefs-metadata-backup";
      RuntimeDirectoryMode = "0700";
      LoadCredential = "juicefs.env:${juicefsEnv}";
      UMask = "0077";
      ExecStart = pkgs.writeShellScript "juicefs-metadata-backup" ''
        set -euo pipefail
        set -a
        source "$CREDENTIALS_DIRECTORY/juicefs.env"
        set +a

        export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
        export AWS_DEFAULT_REGION="auto"
        export AWS_EC2_METADATA_DISABLED="true"

        stamp="$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)"
        snapshot="$RUNTIME_DIRECTORY/juicefs-$stamp.db"
        encrypted="$snapshot.age"

        cleanup() {
          ${pkgs.coreutils}/bin/rm -f "$snapshot" "$encrypted"
        }
        trap cleanup EXIT

        ${pkgs.sqlite}/bin/sqlite3 "${juicefsMetaDb}" \
          ".timeout 30000" \
          ".backup '$snapshot'"

        ${pkgs.age}/bin/age \
          --recipients-file "/home/${username}/.ssh/id_ed25519.pub" \
          --output "$encrypted" \
          "$snapshot"

        ${pkgs.awscli2}/bin/aws s3 cp \
          --endpoint-url "${juicefsR2Endpoint}" \
          --no-progress \
          --only-show-errors \
          "$encrypted" \
          "s3://cloud-storage/juicefs-metadata/juicefs-$stamp.db.age"
      '';
    } // hardening // {
      ProtectHome = "read-only";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  systemd.timers.juicefs-metadata-backup = {
    description = "Daily JuiceFS metadata backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
