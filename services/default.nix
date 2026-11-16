{ config, ... }:

{
  imports = [
    ./cloudflare.nix
    ./avahi.nix
    ./go2rtc.nix
    ./minepanel.nix
    ./slim.nix
    ./wireview-hwmon.nix
  ];

  # Docker's persisted restart policy can resurrect the old unmanaged Dozzle
  # container even after its route is removed. Retain the stopped container.
  systemd.services.retire-dozzle = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    path = [ config.virtualisation.docker.package ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      if docker container inspect local-dozzle-uokrow-dozzle-1 >/dev/null 2>&1; then
        docker update --restart=no local-dozzle-uokrow-dozzle-1 >/dev/null
        docker stop -t 30 local-dozzle-uokrow-dozzle-1 >/dev/null
      fi
    '';
  };
}
