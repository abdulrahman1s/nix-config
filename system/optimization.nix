# Performance, storage, and general system optimizations.
{ pkgs, ... }:

let
  # ── Sysctl tunables (grouped by subsystem) ───────────────
  memSysctl = {
    # zram-only swap: high swappiness is safe — zram is in-RAM compression
    # so there's no I/O penalty; a low value wastes allocated zram capacity.
    "vm.swappiness" = 100;
    # Disable swap readahead: zram has no seek penalty.
    "vm.page-cluster" = 0;
    # Reclaim dentries/inodes more aggressively (default 100).
    "vm.vfs_cache_pressure" = 50;
    # Required by some Proton/Wine games (Hogwarts Legacy, Star Citizen, modded titles).
    "vm.max_map_count" = 2147483642;
    # CachyOS-style writeback: fixed bytes (predictable on any RAM size) + longer
    # flush interval. Reduces NVMe write amplification vs. the percent-based defaults.
    "vm.dirty_bytes" = 268435456; # 256 MiB foreground threshold
    "vm.dirty_background_bytes" = 134217728; # 128 MiB background threshold
    "vm.dirty_writeback_centisecs" = 1500; # flush every 15s (default 5s)
  };

  netSysctl = {
    # Avoid TCP slow-start after brief idle (HTTP keep-alive).
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    # Probe for PMTU blackholes; fall back to smaller MSS.
    "net.ipv4.tcp_mtu_probing" = 1;
    # TCP Fast Open, client-side only.
    "net.ipv4.tcp_fastopen" = 1;
    # BBR congestion control + fq qdisc — better throughput/latency than cubic.
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";
  };

  fsSysctl = {
    # IDEs, file watchers (rclone), and Docker need many watches.
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 1024;
  };

  miscSysctl = {
    # Disable NMI watchdog — saves power and reduces interrupts on desktops.
    "kernel.nmi_watchdog" = 0;
    # Full SysRq (excl. memory dumps) so REISUB can recover a wedged system.
    "kernel.sysrq" = 244;
  };

in
{
  # ── Nix Store ────────────────────────────────────────────
  nix = {
    # Hard-link identical store paths on a timer (avoids per-install slowdown).
    optimise = {
      automatic = true;
      dates = [ "03:45" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # ── Kernel / Boot ───────────────────────────────────────
  boot = {
    kernel.sysctl = memSysctl // netSysctl // fsSysctl // miscSysctl;
    kernelParams = [ "transparent_hugepage=madvise" ]; # Hugepages only when apps opt in
    tmp = {
      useTmpfs = true; # /tmp in RAM — avoids SSD writes, speeds up builds
      tmpfsSize = "50%"; # Leaves headroom; zram (75%) is the real safety net under pressure.
    };
  };

  # ── zram (compressed swap in RAM) ───────────────────────
  zramSwap = {
    enable = true;
    memoryPercent = 75;
    algorithm = "zstd";
  };

  # ── Services ────────────────────────────────────────────
  services = {
    # SSD / filesystem maintenance
    fstrim.enable = true;
    btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
    };

    # Auto nice/ionice for known apps using CachyOS's rule set. Keeps the desktop
    # responsive when background work (builds, indexers, downloads) competes for CPU/IO.
    ananicy = {
      enable = true;
      package = pkgs.ananicy-cpp;
      rulesProvider = pkgs.ananicy-rules-cachyos;
    };

    # Early OOM — kills heaviest process before kernel OOM locks the system.
    earlyoom = {
      enable = true;
      freeMemThreshold = 5; # act when <5 % RAM free
      freeSwapThreshold = 10; # act when <10 % swap free
      enableNotifications = true;
    };

    # Journal size cap
    journald.extraConfig = ''
      SystemMaxUse=1G
      MaxRetentionSec=14d
    '';
  };

  # ── Security ulimits ────────────────────────────────────
  # Raise open-file limits so Docker, browsers, IDEs don't hit the 1024 default.
  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "65536"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "131072"; }
  ];
}
