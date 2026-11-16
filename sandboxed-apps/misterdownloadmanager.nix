{ pkgs, utils, sandboxedXdgUtils, username, config, ... }:

let
  lib = pkgs.lib;
  mdm = pkgs.callPackage ../local-packages/misterdownloadmanager.nix { };

  # MDM keeps its list, settings, IPC token, themes and logs here.
  dataDir = "/.local/share/misterdownloadmanager";

  # Every disk gets one writable folder: ~/Downloads on the root disk and
  # <mount>/Downloads on the others. Missing folders (an absent disk) are
  # skipped by nixpak's bind-try.
  diskMounts = lib.filter (lib.hasPrefix "/mnt/") (builtins.attrNames config.fileSystems);
  diskDownloads = map (mount: "${mount}/Downloads") diskMounts;

  # MDM's own yt-dlp and gallery-dl downloads are FHS binaries that cannot run
  # here. Give it Nix builds at a path that survives updates.
  helpers = pkgs.symlinkJoin {
    name = "misterdownloadmanager-helpers";
    paths = [ pkgs.yt-dlp pkgs.ffmpeg pkgs.gallery-dl ];
  };
  helperDir = "/opt/misterdownloadmanager-helpers";
  programs = pkgs.writeText "programs.json" (builtins.toJSON {
    "yt-dlp" = { version = pkgs.yt-dlp.version; exe = "${helperDir}/yt-dlp"; };
    ffmpeg = { version = pkgs.ffmpeg.version; exe = "${helperDir}/ffmpeg"; };
    "gallery-dl" = { version = pkgs.gallery-dl.version; exe = "${helperDir}/gallery-dl"; };
  });

  # The desktop palette as an MDM theme, on Adwaita's shapes to match the
  # adw-gtk3 GTK theme. Noctalia's custom palette only defines the variants
  # it uses, so each one present becomes the matching MDM side.
  palette = builtins.fromJSON (builtins.readFile ../config/noctalia/palettes/SystemConf.json);
  seeds = colors: {
    background = colors.mSurfaceVariant;
    surface = colors.mSurface;
    header = colors.mSurface;
    text = colors.mOnSurface;
    accent = colors.mPrimary;
    selection = colors.mOutline;
    error = colors.mError;
    warning = colors.mTertiary;
    success = colors.mSecondary;
  };
  themeId = "systemconf";
  theme = (pkgs.formats.toml { }).generate "${themeId}.toml" {
    name = "SystemConf";
    inherits = "adwaita";
    icons = "mono";
    seeds = lib.mapAttrs (_: seeds) (lib.filterAttrs (side: _: side == "light" || side == "dark") palette);
  };
  # A first start's list: the theme picked, dark like the rest of the desktop,
  # and no update checks for a store copy that MDM cannot replace.
  firstList = pkgs.writeText "downloads.json" (builtins.toJSON {
    version = 2;
    next_id = 1;
    items = [ ];
    settings = {
      theme = themeId;
      always_dark = true;
      update_check = false;
    };
  });

  # Seed inside the sandbox, right before MDM starts: on the switch that
  # first persists the data folder, activation can run before impermanence
  # mounts it, leaving the files hidden under the mount.
  seedFile = source: target: ''
    if [ -d "$HOME${dataDir}" ] && [ ! -e "$HOME${dataDir}/${target}" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$HOME${dataDir}/${target}")"
      ${pkgs.coreutils}/bin/install -m 0600 ${source} "$HOME${dataDir}/${target}"
    fi
  '';

  # Inside the sandboxes the release programs are bound at /usr/bin: MDM then
  # identifies a distribution package and does not offer to update itself
  # into the read-only store. /proc/self/exe resolves symlinks, so the bind
  # must be the real directory, entered through its /usr/bin path.
  entry = program: setup: pkgs.writeShellScriptBin program ''
    ${setup}
    exec /usr/bin/${program} "$@"
  '';

  # MDM asks fontconfig for `sans-serif` as its interface font. NixOS's
  # defaults answer DejaVu Sans; answer with the desktop's font (GTK and
  # noctalia use Noto Sans). Script and symbol queries pass through.
  fcMatch = pkgs.writeShellScriptBin "fc-match" ''
    args=()
    for arg in "$@"; do
      if [ "$arg" = sans-serif ]; then arg="Noto Sans"; fi
      args+=("$arg")
    done
    exec ${pkgs.fontconfig.bin}/bin/fc-match "''${args[@]}"
  '';

  sandboxPath = packages: lib.concatStringsSep ":" [
    "/usr/bin"
    helperDir
    (lib.makeBinPath (packages ++ [ pkgs.coreutils sandboxedXdgUtils ]))
  ];

  sharedPerms = {
    bubblewrap.bind.ro = [
      [ "${mdm}/bin" "/usr/bin" ]
      [ "${helpers}/bin" helperDir ]
    ];
    bubblewrap.bind.rw = diskDownloads;
  };

  downloadBinds = [
    { suffix = "/Downloads"; }
    { suffix = dataDir; }
  ];

  app = utils.mkSandboxed {
    package = pkgs.symlinkJoin {
      name = "misterdownloadmanager-entry";
      paths = [
        (entry "misterdownloadmanager" ''
          # MDM restores a missing list from its .bak generations; leave those.
          if [ ! -e "$HOME${dataDir}/downloads.json.bak" ]; then
            ${seedFile firstList "downloads.json"}
          fi
          ${seedFile programs "tools/programs.json"}
          # The sandbox has no Wayland socket. With WAYLAND_DISPLAY set, the
          # clipboard monitor retries Wayland and reconnects every second.
          unset WAYLAND_DISPLAY
        '')
      ];
      postBuild = ''
        ln -s ${mdm}/share $out/share
      '';
    };
    name = "misterdownloadmanager";
    displayName = "Mister Download Manager (Secure)";
    wmClass = "misterdownloadmanager";
    # MDM's default X11 path draws menus as override-redirect popups. Its
    # native Wayland mode turns every menu into a toplevel window instead.
    # No portals: the file chooser would grant any folder. rfd then falls
    # back to zenity, which sees only the folders bound here.
    presets = [
      "network"
      "x11"
      "gpu"
      "notifications"
      "systray"
      "secrets"
    ];
    homeBinds = {
      rw = downloadBinds;
      # GTK settings for zenity's file chooser; the x11 preset omits them.
      ro = [
        { suffix = "/.config/gtk-3.0"; }
        { suffix = "/.config/gtk-4.0"; }
        { suffix = "/.config/dconf"; }
        # MDM runs fc-match for about 30 fonts at start; reuse the host cache.
        { suffix = "/.cache/fontconfig"; }
      ];
    };
    extraPerms = {
      imports = [ sharedPerms ];
      bubblewrap.bind.ro = [
        "/run/current-system/sw/share/themes"
        "/run/current-system/sw/share/icons"
        "/run/current-system/sw/share/glib-2.0"
      ];
      bubblewrap.env.PATH = sandboxPath [ fcMatch pkgs.zenity ];
      bubblewrap.env.GDK_BACKEND = "x11";
      # The desktop's light/dark preference and accent colour.
      dbus.rules.call."org.freedesktop.portal.Desktop" = [
        "org.freedesktop.portal.Settings.*@/org/freedesktop/portal/desktop"
      ];
      # ksni registers the tray icon as StatusNotifierItem-<pid>-<n>; the app
      # is PID 2 in the sandbox's PID namespace.
      dbus.policies."org.kde.StatusNotifierItem-2-1" = "own";
    };
  };

  # The command line downloads by itself, so it gets the same folders.
  cli = utils.mkSandboxed {
    package = entry "misterdownloadmanager-cli" (seedFile programs "tools/programs.json");
    name = "misterdownloadmanager-cli";
    configDir = "misterdownloadmanager";
    exportDesktopFiles = false;
    presets = [ "network" "secrets" ];
    homeBinds.rw = downloadBinds;
    extraPerms = {
      imports = [ sharedPerms ];
      bubblewrap.env.PATH = sandboxPath [ ];
    };
  };

  # The MCP server only reads the IPC endpoint and talks to the app over
  # localhost; the app does the downloading.
  mcp = utils.mkSandboxed {
    package = entry "misterdownloadmanager-mcp" "";
    name = "misterdownloadmanager-mcp";
    configDir = "misterdownloadmanager";
    exportDesktopFiles = false;
    presets = [ "network" ];
    homeBinds.ro = [ { suffix = dataDir; } ];
    extraPerms = {
      bubblewrap.bind.ro = [ [ "${mdm}/bin" "/usr/bin" ] ];
    };
  };

  waitForTray = pkgs.writeShellScript "misterdownloadmanager-wait-for-tray" ''
    # /startup hides MDM in the tray only when a tray host exists at start.
    for _ in $(${pkgs.coreutils}/bin/seq 50); do
      ${pkgs.systemd}/bin/busctl --user status org.kde.StatusNotifierWatcher >/dev/null 2>&1 && exit 0
      ${pkgs.coreutils}/bin/sleep 0.2
    done
  '';
in
{
  packages = [ app cli mcp ];

  module = {
    systemd.user.services.misterdownloadmanager = {
      description = "Mister Download Manager";
      wantedBy = [ "niri.service" ];
      after = [ "niri.service" "noctalia.service" ];
      partOf = [ "niri.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${waitForTray}";
        ExecStart = "${app}/bin/misterdownloadmanager /startup";
      };
    };

    # Brave's sandboxed browser host cannot start the app itself. A connection
    # to this socket (bound into Brave) starts the sandboxed service instead.
    systemd.user.sockets.misterdownloadmanager-launch = {
      description = "Start Mister Download Manager for the browser extension";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "%t/misterdownloadmanager-launch.sock" ];
      socketConfig = {
        Accept = true;
        SocketMode = "0600";
      };
    };
    systemd.user.services."misterdownloadmanager-launch@" = {
      description = "Start Mister Download Manager for the browser extension";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl --user --no-block start misterdownloadmanager.service";
      };
    };

    # Disks are not mounted yet when activation runs at boot; create each
    # folder when its disk is present (a rebuild), never on the root fs.
    system.activationScripts.misterdownloadmanager-disk-downloads.text = ''
      for mount in ${lib.escapeShellArgs diskMounts}; do
        if ${pkgs.util-linux}/bin/mountpoint -q "$mount" && [ ! -e "$mount/Downloads" ]; then
          ${pkgs.coreutils}/bin/install -d -m 0755 -o ${username} -g users "$mount/Downloads"
        fi
      done
    '';

    # The binds above need these to exist before the first launch;
    # impermanence also creates the persisted data folder at boot.
    system.userActivationScripts.misterdownloadmanager-data.text = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 "$HOME${dataDir}"
      if [ ! -e "$HOME/Downloads" ]; then
        ${pkgs.coreutils}/bin/install -d -m 0755 "$HOME/Downloads"
      fi
    '';

    hjem.users.${username}.files = {
      ".local/share/misterdownloadmanager/themes/${themeId}.toml".source = theme;
      # A stable path for agents' MCP registrations across package updates.
      ".local/bin/misterdownloadmanager-mcp".source = "${mcp}/bin/misterdownloadmanager-mcp";
    };
  };
}
