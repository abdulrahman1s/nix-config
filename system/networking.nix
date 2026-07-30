{ config, lib, hostname, lanAddress, lanInterface, username, ... }: {
  # ── DNS-over-QUIC via dnsproxy ─────────────────────────────
  # resolved (127.0.0.53) → dnsproxy (127.0.0.1:5354) → NextDNS DoQ
  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNS = "127.0.0.1:5354";
      Domains = "~.";
      DNSOverTLS = "no";
      FallbackDNS = ""; # no fallback — force all queries through dnsproxy
    };
  };

  services.dnsproxy = {
    enable = true;
    settings = {
      # NextDNS DoQ as primary, Cloudflare DoT as fallback
      fallback = [
        "tls://1.1.1.1:853"
      ];

      # Bootstrap — plain DNS used ONLY to resolve upstream hostnames on first start
      bootstrap = [
        "9.9.9.9:53"
        "149.112.112.112:53"
        "1.1.1.1:53"
        "1.0.0.1:53"
      ];

      listen-addrs = [
        "127.0.0.1"
        "::1"
      ];
      listen-ports = [ 5354 ];

      # Caching — resolved also caches, but this reduces upstream queries
      cache = true;
      cache-min-ttl = 120;
      cache-max-ttl = 86400;
      cache-size = 65536; # 64 KB (dnsproxy counts in bytes, not entries)
      cache-optimistic = true; # serve stale while refreshing in background
    };
    flags = [ "--upstream=%d/nextdns-upstream" ];
  };

  age = {
    # Root and home are wiped on every boot (impermanence), so the early-boot
    # agenix identity lives on the /persist subvolume — mounted neededForBoot=true
    # in initrd, so it is readable when agenix decrypts (~2.7s, before /home).
    # The ~/.ssh path (also persisted) stays as a post-mount fallback.
    identityPaths = [
      "/root/.ssh/id_ed25519"
      "/persist/root/.ssh/id_ed25519"
      "/home/${username}/.ssh/id_ed25519"
    ];
    secrets.nextdns-upstream.file = ../secrets/nextdns-upstream.age;
  };

  systemd.services.dnsproxy.serviceConfig.LoadCredential =
    "nextdns-upstream:${config.age.secrets.nextdns-upstream.path}";

  networking = {
    hostName = hostname;
    networkmanager = {
      enable = true;
      # Prevent NetworkManager from writing its own resolv.conf —
      # resolved handles that via the stub at 127.0.0.53
      dns = lib.mkForce "none";
      # Ignore DHCP-pushed DNS servers so they don't leak into resolved
      # and compete with the global dnsproxy route (127.0.0.1:5354)
      connectionConfig = {
        "ipv4.ignore-auto-dns" = "true";
        "ipv6.ignore-auto-dns" = "true";
        "802-3-ethernet.wake-on-lan" = "64"; # 64 = magic packet
      };
    };
    # ── Static LAN IP ────────────────────────────────────────
    # Fixed address so iPhone Shortcuts can hit a predictable IP.
    networkmanager.ensureProfiles.profiles.wired-static = {
      connection = {
        id = "Wired Static";
        type = "ethernet";
        interface-name = lanInterface;
        autoconnect = "true";
      };
      ipv4 = {
        method = "manual";
        address1 = "${lanAddress}/24,192.168.1.1";
        ignore-auto-dns = "true";
      };
      ipv6 = {
        method = "auto";
        ignore-auto-dns = "true";
      };
      "802-3-ethernet" = {
        wake-on-lan = "64"; # 64 = magic packet
      };
    };

    firewall = {
      enable = true;
      interfaces.${lanInterface}.allowedTCPPorts = [ 8901 ];
    };
  };
}
