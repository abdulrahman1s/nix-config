# Ephemeral root + home: both btrfs subvolumes are rolled back to an empty blank
# on every boot; only the paths below survive. Bootstrap (create the `persist`,
# `root-blank`, `home-blank` subvolumes) and the one-time data migration into
# /persist are manual steps — see the project plan before the first switch.
{ username, ... }:
let
  device = "/dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b";
in
{
  fileSystems."/persist" = {
    inherit device;
    fsType = "btrfs";
    options = [ "subvol=persist" "compress=zstd:1" "noatime" ];
    neededForBoot = true; # mounted in initrd → agenix identity readable early
  };

  # impermanence requires every filesystem that hosts a persisted path to be
  # available before switch-root. The user persist-list lives under /home, so it
  # must be neededForBoot too. Merges with the /home entry in hardware-configuration.nix.
  fileSystems."/home".neededForBoot = true;

  # Wipe `root` and `home` back to a pristine blank before the real filesystems
  # mount. ARMED: everything not under /persist is destroyed on every boot.
  boot.initrd.systemd.services.rollback = {
    description = "Rollback root and home btrfs subvolumes to a pristine state";
    wantedBy = [ "initrd.target" ];
    after = [ "initrd-root-device.target" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs-tmp
      mount -o subvol=/ ${device} /btrfs-tmp
      for sub in root home; do
        btrfs subvolume list -o "/btrfs-tmp/$sub" | cut -f9 -d' ' | while read -r nested; do
          echo "deleting nested subvolume /$nested ..."
          btrfs subvolume delete "/btrfs-tmp/$nested"
        done
        echo "deleting /$sub subvolume ..."
        btrfs subvolume delete "/btrfs-tmp/$sub"
        echo "restoring blank /$sub subvolume ..."
        btrfs subvolume snapshot "/btrfs-tmp/$sub-blank" "/btrfs-tmp/$sub"
      done
      umount /btrfs-tmp
    '';
  };

  environment.persistence."/persist" = {
    hideMounts = true;

    directories = [
      # System identity / nixos state (CRITICAL: stable uid/gid maps)
      "/var/lib/nixos"
      "/var/lib/systemd"
      # Networking
      "/etc/NetworkManager/system-connections"
      "/var/lib/NetworkManager"
      # Bluetooth pairings
      "/var/lib/bluetooth"
      # Containers / virtualisation
      "/var/lib/docker"
      "/var/lib/dokploy"
      "/var/lib/containers"
      "/var/lib/libvirt"
      # Sandboxed Brave private profile (host path)
      "/var/lib/brave-private"
      # Flake-defined service state
      "/var/lib/juicefs" # SQLite metadata db (services/juicefs.nix)
      "/var/cache/juicefs" # cache (rebuildable but large)
      "/var/lib/liquidsoap" # services/radio.nix StateDirectory
      # Journal
      "/var/log"
    ];

    files = [
      "/etc/machine-id"
      "/etc/remote-control.token"
      # /root/.ssh/id_ed25519 is intentionally NOT bind-persisted: agenix reads
      # /persist/root/.ssh/id_ed25519 directly (age.identityPaths), so the bind is
      # redundant and only collides with the existing key before the wipe.
    ];

    # Home is wiped too — only these user paths survive. REVIEW & EXTEND:
    # anything in /home not listed here is destroyed on every boot.
    users.${username} = {
      directories = [
        "system-conf" # the flake repo — explicitly kept
        ".ssh"
        ".cargo"
        ".rustup"
        ".codex"
        ".claude"
        "projects"
        ".anydesk"
        ".config/BraveSoftware" # browser profile (logins, cookies, history)
        ".local/share/zoxide"
        ".local/state/ghostty"
        ".slim" # services/slim.nix ReadWritePaths
        ".npm-global"
        ".bun"
        "Downloads"
        "Pictures"
        "Local"
        "Games"
        "old-Github"
        # ~/Github is a github-fs FUSE mount — never persist it (re-mounts each boot)
        # ── optional / confirm before relying on the wipe ──
        ".local/share/Steam" # gaming module enabled; large (games, library, login)
        ".steam" # Steam locator symlinks + registry.vdf/token; small, complements Steam above
        ".config/Signal"
        ".config/Code"
        ".config/zed"
        ".npm"
        ".cache/ghfs"
        ".cache/qsh"
        ".cache/BraveSoftware"
        ".cache/vicinae"
        ".cache/umu"
        ".cache/nix"
        ".cache/nvidia" # NVIDIA GLCache (compiled GPU shaders); without it every boot recompiles shaders → first-launch stutter in games/GPU apps on the RTX 5090. Self-invalidates on driver bumps.
        ".cache/fontconfig" # per-user fontconfig cache; skips the fc-cache font rescan that hangs the first font-heavy GUI app for seconds after a wipe. Re-keyed (partially regenerated) when a rebuild changes the font set, but valid across plain reboots.
        ".cache/cliphist" # clipboard history db


        ".pki" # NSS cert db (client certs)
        "best-minecraft-ever"
        # ── Desktop/app state the first wipe destroyed; recovered from the
        #    pre-wipe backup snapshot into /persist. Each line notes what broke.
        ".config/dconf" # GTK/GNOME settings — theme, fonts, dark mode (without it nautilus renders light/unreadable)
        ".config/noctalia" # shell: installed plugins + colorschemes (settings/colors/plugins.json stay repo-symlinked via dotfiles.nix)
        ".cache/noctalia" # shell state: current wallpaper, dynamic theming, clipboard history
        ".local/share/keyrings" # gnome-keyring secrets — VSCode safe-storage + Brave cookie/login encryption
        ".icons" # icon + cursor themes (McMojave-circle, We10XOS-cursors) referenced by gtk settings.ini
        ".local/share/icons" # additional icon themes (Tela, We10X, …)
        ".vscode" # editor extensions (.config/Code persists settings/state but NOT extensions)
        # ── Credentials / secrets (chosen to keep; same posture as before — already lived in $HOME) ──
        ".config/gh" # GitHub CLI auth token (hosts.yml)
        ".config/rclone" # rclone remotes + tokens (rclone.conf)
        ".aws" # AWS credentials + config
        ".cloudflared" # cloudflared user creds
        ".docker" # docker CLI config / registry auth / contexts
        # .gnupg intentionally NOT persisted: its private-keys-v1.d is owned by a
        # container-namespace uid (100000), unreadable by the login user — even
        # pre-wipe gpg couldn't use those keys. Re-import real keys if GPG is needed.
        ".local/share/applications" # custom .desktop launchers
      ];
      files = [
        # .zshrc is recreated every boot by terminal/shell.nix (touch ~/.zshrc) — not data
        ".zsh_history"
        ".qsh_known"
        ".bash_history"
        ".zsh_secrets"
        ".config/mimeapps.list" # default-app associations (file; apps that rewrite it via atomic-rename may not re-persist edits — re-set if it drifts)
        ".claude.json" # Claude Code oauthAccount + hasCompletedOnboarding (token is in persisted ~/.claude/.credentials.json); without this Claude re-runs sign-up every boot. CLAUDE_CONFIG_DIR does NOT relocate this file.
      ];
    };
  };
}
