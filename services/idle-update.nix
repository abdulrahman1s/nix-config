{ config, pkgs, username, ... }:

# Background NixOS update, at most every 3 days. After an hour of quiet CPU and
# network, it fast-forwards ~/system-conf to GitHub's master (where CI commits
# input and package updates and pre-builds them into the binary cache),
# downloads/builds that system slowly on one core, then installs it as the
# default for the next boot. The running system is never switched.
#
# A run cut short by shutdown or `systemctl stop` resumes after the next boot.
# Nix keeps every store path it finished downloading; only the path in flight
# at the interruption starts over.
let
  user = config.users.users.${username};
  flake = "${user.home}/system-conf";
  attr = "${flake}#nixosConfigurations.default.config.system.build.toplevel";
  # The repo is public; anonymous HTTPS keeps SSH keys (including the FIDO
  # key that waits for a touch) out of a background job.
  repoUrl = "https://github.com/abdulrahman1s/nix-config.git";
  # Persisted in system/impermanence.nix; marks an update to resume.
  pending = "/var/lib/idle-update/pending";
  # A direct GC root; its mtime doubles as the last-success stamp because
  # /nix survives the root rollback and /run does not.
  gcRoot = "/nix/var/nix/gcroots/idle-update";

  # 1 Mbit/s. Nix's download-speed is in KiB/s and caps each transfer, so the
  # build also runs one substitution at a time to make it a total cap.
  downloadKiB = "122";
  # Both SMT threads of physical core 7 (`lscpu -e`).
  cpuThreads = "7 15";
  buildCores = "2";

  idleMinutes = "60";
  # Per-minute averages that count as idle: under 5% of all CPU time and
  # under 25 KB/s on physical NICs.
  idleCpuPermille = "50";
  idleNetBytesPerSec = "25000";
  intervalDays = "3";
  # A failed or skipped run waits this long before the next idle window.
  retryHours = "24";
  # Delay after boot before resuming an interrupted update.
  resumeDelaySec = "300";

  gib = 1024 * 1024 * 1024;
  # The same floors as `update` in config/zsh/update.zsh.
  startDfFloor = toString (35 * gib);
  startBtrfsFloor = toString (20 * gib);
  emergencyDfFloor = toString (20 * gib);
  emergencyBtrfsFloor = toString (8 * gib);
  bootFloor = toString (256 * 1024 * 1024);
in
{
  systemd.services.idle-update = {
    description = "Pull, download, and install the next NixOS update for the next boot";
    # A rebuild must not restart an update that may be hours into a download.
    restartIfChanged = false;
    path = [
      config.nix.package
      config.system.build.nixos-rebuild
      pkgs.git
      pkgs.util-linux
      pkgs.btrfs-progs
      pkgs.gawk
      pkgs.nvd
    ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "idle-update";
      # Local builds and NAR decompression run in this cgroup: root uses the
      # store directly rather than through nix-daemon.
      AllowedCPUs = cpuThreads;
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
    script = ''
      # Shutdown and `systemctl stop` must exit before any failure handling so
      # the pending update survives to resume. Dying by the signal itself lets
      # systemd count the stop as clean rather than failed.
      trap 'trap - TERM; kill -TERM $$' TERM

      # Git and evaluation run as the user, so root never writes to or
      # evaluates the repo. The daemon ignores download-speed from untrusted
      # users, but any input fetch during evaluation happens client-side,
      # where it applies.
      as_user() {
        setpriv --reuid=${username} --regid=${user.group} --init-groups --reset-env \
          ${pkgs.coreutils}/bin/env PATH="$PATH" "$@"
      }

      free_df() {
        df --output=avail -B1 "$1" | awk 'NR == 2 { print $1 }'
      }

      # Conservative Btrfs estimate, parsed like _smart_update_btrfs_min_bytes.
      free_btrfs() {
        local value
        value=$(btrfs filesystem usage -b /nix/store 2>/dev/null | awk '
          /Free \(estimated\):/ {
            for (i = 1; i <= NF; i++) {
              if ($i == "(min:") {
                value = $(i + 1)
                gsub(/[^0-9]/, "", value)
                print value
                exit
              }
            }
          }
        ')
        echo "''${value:-$(free_df /nix/store)}"
      }

      space_ok() {
        [ "$(free_df /nix/store)" -ge "$1" ] && [ "$(free_btrfs)" -ge "$2" ]
      }

      if ! space_ok ${startDfFloor} ${startBtrfsFloor}; then
        echo "less than 35 GiB free (or 20 GiB by the Btrfs estimate) on /nix; skipping" >&2
        exit 1
      fi

      branch=$(as_user git -C ${flake} symbolic-ref --short HEAD)
      if [ "$branch" != master ]; then
        echo "${flake} is on '$branch', not master; skipping" >&2
        rm -f ${pending}
        exit 1
      fi

      as_user git -C ${flake} fetch --quiet ${repoUrl} \
        +refs/heads/master:refs/remotes/origin/master
      # Git aborts without touching anything when local commits diverge or
      # uncommitted edits overlap the incoming changes.
      if ! as_user git -C ${flake} merge --ff-only --quiet origin/master; then
        echo "cannot fast-forward ${flake} to origin/master; commit/push or stash local work. Skipping" >&2
        rm -f ${pending}
        exit 1
      fi
      echo "${flake} is at $(as_user git -C ${flake} log -1 --format='%h %s')"
      touch ${pending}

      # A generation activated during a long download may carry newer config;
      # re-evaluate on top of it so the boot default never goes backwards.
      # Paths already downloaded make each extra round cheap.
      for _ in 1 2 3; do
        generation=$(readlink /nix/var/nix/profiles/system)

        if ! drv=$(as_user nix eval --raw "${attr}.drvPath" \
          --no-write-lock-file \
          --option download-speed ${downloadKiB}); then
          rm -f ${pending}
          exit 1
        fi

        echo "building $drv at about 1 Mbit/s on CPUs ${cpuThreads}"
        nix build "$drv^*" \
          --out-link ${gcRoot} \
          --option download-speed ${downloadKiB} \
          --option max-substitution-jobs 1 \
          --option cores ${buildCores} &
        build=$!

        while kill -0 "$build" 2>/dev/null; do
          if ! space_ok ${emergencyDfFloor} ${emergencyBtrfsFloor}; then
            echo "free space on /nix fell below 20 GiB (or 8 GiB by the Btrfs estimate); stopping" >&2
            kill "$build"
            wait "$build" || true
            exit 1
          fi
          sleep 30
        done

        if ! wait "$build"; then
          rm -f ${pending}
          exit 1
        fi

        [ "$(readlink /nix/var/nix/profiles/system)" = "$generation" ] && break
        echo "a new system generation appeared during the download; re-evaluating"
      done

      if [ "$(readlink /nix/var/nix/profiles/system)" != "$generation" ]; then
        echo "system generations kept changing; will retry later"
        exit 0
      fi

      out=$(readlink -f ${gcRoot})
      if [ "$out" = "$(readlink -f /nix/var/nix/profiles/system)" ]; then
        echo "no changes; $out is already the boot default"
        rm -f ${pending}
        exit 0
      fi

      if [ "$(free_df /boot)" -lt ${bootFloor} ]; then
        echo "less than 256 MiB free on /boot; not installing" >&2
        exit 1
      fi

      nvd diff /run/current-system "$out" || true
      nixos-rebuild boot --no-reexec --store-path "$out"
      rm -f ${pending}
      echo "installed $out as the default for the next boot"
    '';
  };

  systemd.services.idle-update-watch = {
    description = "Start idle-update.service after an idle hour, at most every 3 days";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      RuntimeDirectory = "idle-update-watch";
      # Keeps the attempt stamp across watcher restarts (a rebuild), so only
      # a real boot resumes a pending update right away.
      RuntimeDirectoryPreserve = true;
      Restart = "on-failure";
      RestartSec = 60;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    script = ''
      attempt="$RUNTIME_DIRECTORY/last-attempt"

      start_update() {
        touch "$attempt"
        systemctl start --no-block idle-update.service
      }

      read_cpu() {
        local _ user nice system idle iowait irq softirq steal
        read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
        cpu_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        cpu_idle=$((idle + iowait))
      }

      # Physical NICs only; veth, bridge, and tunnel traffic would double count.
      read_net() {
        local dev rx tx
        net_bytes=0
        for dev in /sys/class/net/*; do
          [ -e "$dev/device" ] || continue
          read -r rx < "$dev/statistics/rx_bytes"
          read -r tx < "$dev/statistics/tx_bytes"
          net_bytes=$((net_bytes + rx + tx))
        done
      }

      older_than() {
        [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
        [ $(($(date +%s) - $(stat -c %Y "$1"))) -ge "$2" ]
      }

      due() {
        older_than "$attempt" $((${retryHours} * 3600)) && {
          [ -e ${pending} ] || older_than ${gcRoot} $((${intervalDays} * 86400))
        }
      }

      if [ -e ${pending} ] && [ ! -e "$attempt" ]; then
        echo "resuming the interrupted update in ${resumeDelaySec} s"
        sleep ${resumeDelaySec}
        start_update
      fi

      streak=0
      waited=0
      read_cpu
      read_net
      while sleep 60; do
        prev_total=$cpu_total prev_idle=$cpu_idle prev_net=$net_bytes
        read_cpu
        read_net
        busy=$((1000 * ((cpu_total - prev_total) - (cpu_idle - prev_idle)) / (cpu_total - prev_total)))
        rate=$(((net_bytes - prev_net) / 60))

        if ! due; then
          streak=0
          waited=0
          continue
        fi

        # Hourly while due, so a background load that never lets the machine
        # look idle shows up in the journal instead of silently blocking runs.
        waited=$((waited + 1))
        if [ $((waited % 60)) -eq 0 ]; then
          echo "waiting for idle: streak $streak/${idleMinutes} min (cpu $((busy / 10)).$((busy % 10))%, net $((rate / 1000)) KB/s)"
        fi

        if [ "$busy" -lt ${idleCpuPermille} ] && [ "$rate" -lt ${idleNetBytesPerSec} ]; then
          streak=$((streak + 1))
        else
          # Logged so the thresholds can be tuned from the journal.
          if [ "$streak" -ge 15 ]; then
            echo "idle streak ended after $streak min (cpu $((busy / 10)).$((busy % 10))%, net $((rate / 1000)) KB/s)"
          fi
          streak=0
        fi

        if [ "$streak" -ge ${idleMinutes} ]; then
          echo "idle for ${idleMinutes} min; starting idle-update.service"
          start_update
          streak=0
        fi
      done
    '';
  };
}
