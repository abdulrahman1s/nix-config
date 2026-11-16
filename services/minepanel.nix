{ config, pkgs, username, ... }:

let
  stateDir = "/var/lib/minepanel";
  environmentFile = "${stateDir}/minepanel.env";
  rootlessDir = "${stateDir}/rootless";
  podmanHome = "${stateDir}/podman-home";
  podmanRuntime = "/run/user/1101";
  podmanSocket = "/run/minepanel-podman.sock";
  podman = config.virtualisation.podman.package;
  # ProtectHome = true also hides /run/user, where rootless Podman keeps its
  # runtime state; Podman then exits before starting anything. Hide home
  # directories behind an empty tmpfs and bind back only this account's runtime.
  podmanIsolation = {
    ProtectHome = "tmpfs";
    BindPaths = [ podmanRuntime ];
    InaccessiblePaths = [ "/persist/home" "/persist/root" ];
  };

  oldDataDir =
    "/var/lib/docker/volumes/games-minepanel-rnwhi4_minepanel-data/_data";
  oldPanelServersDir =
    "/var/lib/docker/volumes/games-minepanel-rnwhi4_minepanel-servers/_data";
  oldRuntimeServersDir =
    "/var/lib/docker/volumes/games-minepanel-rnwhi4_minepanel-servers/servers";
  oldServersPrefix =
    "/var/lib/docker/volumes/games-minepanel-rnwhi4_minepanel-servers";
in
{
  # Swarm state is persisted in /var/lib/docker; Docker rejects live restore
  # when joining that swarm, so the old-stateVersion default prevents startup.
  virtualisation.docker.daemon.settings."live-restore" = false;

  # Keep the existing unrelated Docker workloads; MinePanel uses its own
  # rootless Podman account and cannot control the host Docker daemon.
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers = {
    minepanel-backend = {
      podman.user = "minepanel";
      image =
        "ketbom/minepanel-backend@sha256:8203a0158932cf5a19f1522a28168fc72e12f496621925d7ec197ba992c9b49e";
      environment = {
        NODE_ENV = "production";
        FRONTEND_URL = "https://minecraft.test";
      };
      environmentFiles = [ "${rootlessDir}/minepanel.env" ];
      volumes = [
        "${rootlessDir}/servers:/app/servers"
        "${rootlessDir}/data:/app/data"
        "${podmanSocket}:/var/run/docker.sock"
      ];
      ports = [ "127.0.0.1:8091:8091" ];
    };

    minepanel-frontend = {
      podman.user = "minepanel";
      image =
        "ketbom/minepanel-frontend@sha256:ffbb7588982a213565547d2dab05ad8bb3b6f4b00220ef31738ddcb9f7a71725";
      environment = {
        NEXT_PUBLIC_BACKEND_URL = "https://minecraft.test/backend";
        NEXT_PUBLIC_DEFAULT_LANGUAGE = "en";
      };
      dependsOn = [ "minepanel-backend" ];
      ports = [ "127.0.0.1:3001:3000" ];
    };
  };

  users.groups.minepanel.gid = 1101;
  users.users.minepanel = {
    isSystemUser = true;
    # Rootless OCI services need a stable runtime-directory path.
    uid = 1101;
    group = "minepanel";
    home = podmanHome;
    createHome = true;
    homeMode = "0700";
    linger = true;
    subUidRanges = [{ startUid = 1100000; count = 65536; }];
    subGidRanges = [{ startGid = 1100000; count = 65536; }];
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];

  systemd.sockets.minepanel-podman = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = podmanSocket;
      SocketUser = "minepanel";
      SocketGroup = "minepanel";
      SocketMode = "0600";
    };
  };

  systemd.services.minepanel-podman = {
    requires = [ "user@1101.service" ];
    after = [ "user@1101.service" ];
    environment = { HOME = podmanHome; XDG_RUNTIME_DIR = podmanRuntime; };
    serviceConfig = {
      User = "minepanel";
      Group = "minepanel";
      ExecStart = "${podman}/bin/podman system service --time=0";
      Delegate = true;
      # newuidmap/newgidmap must retain their privilege for rootless mappings.
      UMask = "0077";
    } // podmanIsolation;
  };

  systemd.services.minepanel-rootless-migrate = {
    requires = [ "minepanel-prepare.service" "user@1101.service" ];
    after = [ "minepanel-prepare.service" "user@1101.service" ];
    before = [ "podman-minepanel-backend.service" "podman-minepanel-frontend.service" ];
    unitConfig.RequiresMountsFor = [ stateDir ];
    path = with pkgs; [ acl coreutils docker util-linux podman ];
    environment = {
      MINEPANEL_STATE_DIR = stateDir;
      MINEPANEL_PODMAN_HOME = podmanHome;
      MINEPANEL_RUNTIME_DIR = podmanRuntime;
      MINEPANEL_PODMAN = "${podman}/bin/podman";
      MINEPANEL_LOGIN_USER = username;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
      ExecStart = "${pkgs.python3}/bin/python3 ${./minepanel-rootless-migrate.py}";
    };
  };

  systemd.services.podman-minepanel-backend = {
    after = [ "minepanel-rootless-migrate.service" "minepanel-podman.socket" "user@1101.service" ];
    requires = [ "minepanel-rootless-migrate.service" "minepanel-podman.socket" "user@1101.service" ];
    environment.XDG_RUNTIME_DIR = podmanRuntime;
    serviceConfig = podmanIsolation;
  };
  systemd.services.podman-minepanel-frontend = {
    requires = [ "user@1101.service" ];
    after = [ "user@1101.service" ];
    environment.XDG_RUNTIME_DIR = podmanRuntime;
    serviceConfig = podmanIsolation;
  };

  systemd.services.minepanel-servers = {
    description = "Restore rootless Minecraft containers with a restart policy";
    wantedBy = [ "multi-user.target" ];
    requires = [ "podman-minepanel-backend.service" ];
    after = [ "podman-minepanel-backend.service" ];
    environment = { HOME = podmanHome; XDG_RUNTIME_DIR = podmanRuntime; };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "minepanel";
      Group = "minepanel";
      ExecStart = "${podman}/bin/podman start --all --filter should-start-on-boot=true --filter label=com.docker.compose.project";
      ExecStop = "${podman}/bin/podman stop --service --all --filter label=com.docker.compose.project --time=120";
      TimeoutStopSec = 150;
    } // podmanIsolation;
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root -"
    "d ${stateDir}/data 0755 root root -"
    "d ${stateDir}/servers 0755 root root -"
    "d ${stateDir}/servers/minecraft 0755 root root -"
    "d ${stateDir}/servers/minecraft/backups 0755 root root -"
  ];

  # Dokploy used named volumes for /app/{data,servers}. MinePanel's child
  # containers need host bind paths, so that deployment split panel-visible
  # files under _data from the live server/world/backup tree beside it.
  # Merge both copies once, without deleting the old volumes.
  systemd.services.minepanel-prepare = {
    description = "Prepare and migrate MinePanel state";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = [
      "podman-minepanel-backend.service"
      "podman-minepanel-frontend.service"
    ];
    unitConfig.RequiresMountsFor = [ stateDir ];
    path = with pkgs; [
      coreutils
      docker
      findutils
      gnused
      openssl
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu

      install -d -m 0755 \
        ${stateDir} \
        ${stateDir}/data \
        ${stateDir}/servers \
        ${stateDir}/servers/minecraft \
        ${stateDir}/servers/minecraft/backups

      if [ ! -s ${environmentFile} ]; then
        secret="$(
          docker inspect games-minepanel-rnwhi4-backend-1 \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | sed -n 's/^JWT_SECRET=//p' \
            | head -n 1
        )"
        if [ -z "$secret" ]; then
          secret="$(openssl rand -hex 32)"
        fi

        umask 077
        temporary_environment="$(mktemp ${stateDir}/minepanel.env.XXXXXX)"
        printf 'JWT_SECRET=%s\n' "$secret" > "$temporary_environment"
        mv "$temporary_environment" ${environmentFile}
      fi

      # Remove the old panel containers on every boot so Docker's
      # unless-stopped policy cannot let them reclaim ports 3001/8091.
      for container in \
        games-minepanel-rnwhi4-frontend-1 \
        games-minepanel-rnwhi4-backend-1
      do
        docker stop -t 120 "$container" >/dev/null 2>&1 || true
      done

      migration_marker=${stateDir}/.migrated-from-dokploy-v1
      if [ ! -e "$migration_marker" ]; then
        # Stop the old child containers so the Minecraft world is consistent
        # while copied. These generic names must only be removed during the
        # initial migration; the Nix-managed panel will reuse them afterward.
        for container in \
          minecraft-backup \
          minecraft
        do
          docker stop -t 120 "$container" >/dev/null 2>&1 || true
        done

        if [ -d ${oldDataDir} ]; then
          cp -a ${oldDataDir}/. ${stateDir}/data/
        fi
        if [ -d ${oldPanelServersDir} ]; then
          cp -a ${oldPanelServersDir}/. ${stateDir}/servers/
        fi
        if [ -d ${oldRuntimeServersDir} ]; then
          cp -a ${oldRuntimeServersDir}/. ${stateDir}/servers/
        fi

        # Existing generated Compose files contain the old Dokploy host path.
        find ${stateDir}/servers -mindepth 2 -maxdepth 2 \
          -name docker-compose.yml -type f \
          -exec sed -i \
            's#${oldServersPrefix}#${stateDir}#g' \
            '{}' +

        docker rm -f minecraft-backup minecraft >/dev/null 2>&1 || true
        touch "$migration_marker"
      fi

      docker rm -f \
        games-minepanel-rnwhi4-frontend-1 \
        games-minepanel-rnwhi4-backend-1 \
        >/dev/null 2>&1 || true
    '';
  };

}
