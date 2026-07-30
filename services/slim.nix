{ pkgs, username, ... }:

let
  hardening = import ../system/hardening.nix;
  slim = pkgs.callPackage ../local-packages/slim.nix { };

  slimServices = [
    { domain = "homeassistant"; port = 8123; }
    { domain = "homebridge"; port = 8581; }
    { domain = "logging"; port = 7777; }
    { domain = "radio"; port = 4444; }
    { domain = "dokploy"; port = 3000; }
    {
      domain = "minecraft";
      port = 3001;
      routes = [
        { path = "/backend"; port = 8091; }
      ];
    }
  ];

  slimConfigFile = (pkgs.formats.yaml { }).generate "slim-config.yaml" {
    services = map
      (s:
        { inherit (s) domain port; }
        // (if s ? routes then { inherit (s) routes; } else { }))
      slimServices;
    log_mode = "minimal";
    cors = false;
  };
in

{
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
            IP6T="${pkgs.iptables}/bin/ip6tables"
            # Local names may resolve to ::1 first; redirect both families so
            # Docker-published ports cannot intercept Slim domains.
            # Create SLIM chain (ignore error if already exists)
            $IPT -t nat -N SLIM 2>/dev/null || true
            $IP6T -t nat -N SLIM 2>/dev/null || true
            # Add redirect rules into the SLIM chain
            $IPT -t nat -C SLIM -p tcp -d 127.0.0.1/32 --dport 80 -j REDIRECT --to-ports 10080 2>/dev/null \
              || $IPT -t nat -A SLIM -p tcp -d 127.0.0.1/32 --dport 80 -j REDIRECT --to-ports 10080
            $IPT -t nat -C SLIM -p tcp -d 127.0.0.1/32 --dport 443 -j REDIRECT --to-ports 10443 2>/dev/null \
              || $IPT -t nat -A SLIM -p tcp -d 127.0.0.1/32 --dport 443 -j REDIRECT --to-ports 10443
            $IP6T -t nat -C SLIM -p tcp -d ::1/128 --dport 80 -j REDIRECT --to-ports 10080 2>/dev/null \
              || $IP6T -t nat -A SLIM -p tcp -d ::1/128 --dport 80 -j REDIRECT --to-ports 10080
            $IP6T -t nat -C SLIM -p tcp -d ::1/128 --dport 443 -j REDIRECT --to-ports 10443 2>/dev/null \
              || $IP6T -t nat -A SLIM -p tcp -d ::1/128 --dport 443 -j REDIRECT --to-ports 10443
            # Jump from OUTPUT into SLIM (on loopback, matching slim's doctor check)
            $IPT -t nat -C OUTPUT -o lo -p tcp -j SLIM 2>/dev/null \
              || $IPT -t nat -I OUTPUT 1 -o lo -p tcp -j SLIM
            $IP6T -t nat -C OUTPUT -o lo -p tcp -j SLIM 2>/dev/null \
              || $IP6T -t nat -I OUTPUT 1 -o lo -p tcp -j SLIM
          '';
        in
        "+${natUp}";
      ExecStopPost =
        let
          natDown = pkgs.writeScript "slim-nat-down" ''
            #!${pkgs.bash}/bin/bash
            IPT="${pkgs.iptables}/bin/iptables"
            IP6T="${pkgs.iptables}/bin/ip6tables"
            $IPT -t nat -D OUTPUT -o lo -p tcp -j SLIM 2>/dev/null || true
            $IPT -t nat -F SLIM 2>/dev/null || true
            $IPT -t nat -X SLIM 2>/dev/null || true
            $IP6T -t nat -D OUTPUT -o lo -p tcp -j SLIM 2>/dev/null || true
            $IP6T -t nat -F SLIM 2>/dev/null || true
            $IP6T -t nat -X SLIM 2>/dev/null || true
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

  security.pki.certificateFiles = [ ../slim-ca.pem ];
}
