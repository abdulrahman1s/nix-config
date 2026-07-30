{ pkgs, ... }:

let
  stateDir = "/var/lib/minepanel";
  environmentFile = "${stateDir}/minepanel.env";

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
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers = {
    minepanel-backend = {
      image =
        "ketbom/minepanel-backend@sha256:7d47bc26f234d4dbdcad5b94506a17bac81f9b89aa599d2cfa8ad9962ace5889";
      environment = {
        NODE_ENV = "production";
        FRONTEND_URL = "https://minecraft.test";
      };
      environmentFiles = [ environmentFile ];
      volumes = [
        "${stateDir}/servers:/app/servers"
        "${stateDir}/data:/app/data"
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
      ports = [ "8091:8091" ];
    };

    minepanel-frontend = {
      image =
        "ketbom/minepanel-frontend@sha256:876507fce1682ad149bb03bcaad0453c1df666dee64825ddec06903f17c86bb8";
      environment = {
        NEXT_PUBLIC_BACKEND_URL = "https://minecraft.test/backend";
        NEXT_PUBLIC_DEFAULT_LANGUAGE = "en";
      };
      dependsOn = [ "minepanel-backend" ];
      ports = [ "3001:3000" ];
    };
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
      "docker-minepanel-backend.service"
      "docker-minepanel-frontend.service"
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

  systemd.services.docker-minepanel-backend = {
    after = [ "minepanel-prepare.service" ];
    requires = [ "minepanel-prepare.service" ];
  };
}
