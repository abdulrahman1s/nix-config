{ config, ... }:

let
  dokployDbPassword = config.age.secrets.dokploy-db-password.path;
  dokployAuthSecret = config.age.secrets.dokploy-auth-secret.path;
in

{
  age.secrets = {
    dokploy-db-password.file = ../secrets/dokploy-db-password.age;
    dokploy-auth-secret.file = ../secrets/dokploy-auth-secret.age;
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
}
