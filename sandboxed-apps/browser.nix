{ pkgs, utils, sandboxedXdgUtils, inputs, username, config, ... }:

let
  braveOrigin = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.brave-origin;
  rtxVsr = import ../local-packages/linux-rtx-vsr.nix { inherit pkgs; };
  vsrHost = pkgs.writeShellScript "linux-rtx-vsr-native-host" ''
    # CUDA's default ~/.nv cache is ephemeral inside the browser sandbox.
    export CUDA_CACHE_PATH="$HOME/.cache/nvidia/ComputeCache"
    ${pkgs.coreutils}/bin/mkdir -p "$CUDA_CACHE_PATH"
    exec ${rtxVsr}/bin/linux-rtx-vsr native-host "$@"
  '';
  vsrManifestName = "io.github.abdulrahman1s.linux_rtx_vsr.json";
  vsrManifest = pkgs.writeText vsrManifestName (builtins.toJSON {
    name = "io.github.abdulrahman1s.linux_rtx_vsr";
    description = "Linux RTX VSR native integration";
    path = toString vsrHost;
    type = "stdio";
    allowed_origins = [ "chrome-extension://pdobgdmlfcnimbnndkchfocncchfoadm/" ];
  });
  mdm = pkgs.callPackage ../local-packages/misterdownloadmanager.nix { };
  # MDM's host starts the program named in `app-path` beside itself when the
  # app is not running. From inside Brave's sandbox it can only ask the user
  # manager, through the socket in sandboxed-apps/misterdownloadmanager.nix.
  mdmStart = pkgs.writeShellScript "misterdownloadmanager-start" ''
    exec ${pkgs.socat}/bin/socat -u OPEN:/dev/null \
      UNIX-CONNECT:"$XDG_RUNTIME_DIR/misterdownloadmanager-launch.sock"
  '';
  # A copy, not a symlink: the host finds `app-path` through /proc/self/exe.
  mdmHost = pkgs.runCommandLocal "misterdownloadmanager-browser-host" { } ''
    mkdir -p "$out"
    cp ${mdm}/libexec/misterdownloadmanager-host/misterdownloadmanager-nmhost "$out/"
    printf %s ${mdmStart} > "$out/app-path"
  '';
  mdmManifestName = "com.misterdownloadmanager.host.json";
  mdmManifest = pkgs.writeText mdmManifestName (builtins.toJSON {
    name = "com.misterdownloadmanager.host";
    description = "Mister Download Manager";
    path = "${mdmHost}/misterdownloadmanager-nmhost";
    type = "stdio";
    # The ID the unpacked extension's manifest key gives it.
    allowed_origins = [ "chrome-extension://oogbclbbninliongijffeeggalppliok/" ];
  });
  warpHosts = config.services.cloudflare-warp-proxy.braveHosts;
  warpVersion = (builtins.fromJSON (builtins.readFile ../config/brave-warp-extension/manifest.json)).version;

  warpBackground = pkgs.writeText "background.js" (
    builtins.replaceStrings
      [ "@WARP_HOSTS@" ]
      [ (builtins.toJSON warpHosts) ]
      (builtins.readFile ../config/brave-warp-extension/background.js.in)
  );
  warpBuildInfo = pkgs.writeText "build.js" ''
    globalThis.warpBuild = ${builtins.toJSON { version = warpVersion; hosts = warpHosts; }};
  '';
  warpExtension = pkgs.runCommandLocal "brave-warp-extension"
    { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    mkdir -p "$out"
    cp ${../config/brave-warp-extension/manifest.json} "$out/manifest.json"
    cp ${warpBackground} "$out/background.js"
    cp ${warpBuildInfo} "$out/build.js"
    cp ${../config/brave-warp-extension/popup.html} "$out/popup.html"
    cp ${../config/brave-warp-extension/popup.css} "$out/popup.css"
    cp ${../config/brave-warp-extension/popup.js} "$out/popup.js"
    for size in 16 32 48 128; do
      rsvg-convert -w "$size" -h "$size" \
        ${../config/brave-warp-extension/icon.svg} -o "$out/icon-$size.png"
    done
  '';

  chromiumWaylandArgs = [
    "--enable-features=UseOzonePlatform,WaylandWindowDecorations,VaapiVideoDecoder,VaapiVideoEncoder,VaapiIgnoreDriverChecks,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder,VaapiOnNvidiaGPUs"
    "--ozone-platform-hint=auto"
    # Keep NVIDIA's accelerated video path available to the browser.
    "--use-gl=angle"
    "--use-angle=gl"
    # Retain the package wrapper's disabled features when adding Vulkan.
    "--disable-features=OutdatedBuildDetector,UseChromeOSDirectVideoDecoder,Vulkan"
    "--ignore-gpu-blocklist"
    "--enable-gpu-rasterization"
    "--enable-zero-copy"
  ];

  # ── Factory ────────────────────────────────────────────────────────────────
  mkBrave =
    { name
    , displayName ? null
    , configDir ? "BraveSoftware/Brave-Origin-Nightly"
    , exportDesktopFiles ? true
    , extraBinNames ? [ ]
    , wmClass ? null
    , resourceLimits ? null
    , userDataDir ? null
    , extraBraveArgs ? [ ]
    , presets ? [
        "network"
        "wayland"
        "audio"
        "gpu"
        "usb"
        "portals"
        "notifications"
        "secrets"
        "systray"
        "mpris"
        "bluetooth"
        "u2f"
      ]
    ,
    }:
    let
      # Keep the profile path stable; TMPDIR is a short bind of its shared
      # singleton directory so separate launches can reach the same socket.
      wrappedBrave = pkgs.writeShellScriptBin name ''
        ${pkgs.coreutils}/bin/mkdir -p "$TMPDIR"
        ${pkgs.lib.optionalString (name == "brave") ''
          export LIBVA_DRIVER_NAME=nvidia
        ''}
        exec ${braveOrigin}/bin/brave-origin \
          ${
            if userDataDir == null then
              ''--user-data-dir="$HOME/.config/${configDir}"''
            else
              "--user-data-dir=${pkgs.lib.escapeShellArg userDataDir}"
          } \
          ${pkgs.lib.escapeShellArgs (
            pkgs.lib.optionals (builtins.elem "wayland" presets) chromiumWaylandArgs
            ++ extraBraveArgs
          )} \
          "$@"
      '';

      bravePackage = pkgs.symlinkJoin {
        name = "brave-wrapped-${name}";
        paths = [ wrappedBrave ];
        postBuild = ''
          ln -s ${braveOrigin}/share $out/share
        '';
      };

      sandboxArgs = {
        inherit
          name
          displayName
          configDir
          exportDesktopFiles
          extraBinNames
          wmClass
          presets
          ;
        package = bravePackage;
        binPath = "bin/${name}";
        homeBinds.rw = pkgs.lib.optionals (name == "brave") [
          { suffix = "/.config/linux-rtx-vsr"; }
          { suffix = "/.local/state/linux-rtx-vsr"; }
          { suffix = "/.local/share/linux-rtx-vsr"; }
        ] ++ [
          { suffix = "/.pki/nssdb"; }
          { suffix = "/Downloads"; }
          # Chromium puts the HTTP disk cache under ~/.cache/<configDir>, NOT in
          # the user-data-dir. Without binding it through, the cache writes to the
          # sandbox's ephemeral root and is lost on every browser exit. Bind the
          # BraveSoftware parent (impermanence-persisted, so it always exists at
          # bind time) rather than the leaf, which may not exist on a fresh boot.
          { suffix = "/.cache/BraveSoftware"; }
          # Reuse the persisted fontconfig index instead of rescanning fonts
          # inside each short-lived browser sandbox.
          { suffix = "/.cache/fontconfig"; }
        ];
        # MDM's host reads the app's IPC port and token there. The app
        # replaces ipc.json on each start, so bind the folder, not the file.
        homeBinds.ro = pkgs.lib.optionals (name == "brave") [
          { suffix = "/.local/share/misterdownloadmanager"; }
        ];
        extraPackages = [
          sandboxedXdgUtils
          pkgs.cosmic-files
          pkgs.brotab
        ];
      };

      # Unix socket paths must fit in 107 bytes. Keep the shared directory
      # outside /tmp: nixpak mounts its private /tmp after the bind mounts,
      # which would hide the singleton socket from subsequent launches.
      extraPerms =
        { sloth, ... }:
        {
          bubblewrap.env.TMPDIR = "/run/${name}-singleton";
          bubblewrap.bind.rw = [
            [
              (sloth.mkdir (sloth.concat' sloth.homeDir "/.config/${configDir}/.singleton-tmp"))
              "/run/${name}-singleton"
            ]
          ] ++ pkgs.lib.optionals (name == "brave") [
            # Create the persisted cache before binding, including on first launch.
            (sloth.mkdir (sloth.concat' sloth.homeDir "/.cache/nvidia/ComputeCache"))
            # connect() needs write access; the socket only starts MDM.
            (sloth.concat' sloth.runtimeDir "/misterdownloadmanager-launch.sock")
          ];
          bubblewrap.bind.ro = pkgs.lib.optionals (name == "brave") [
            "/etc/brave-warp-extension"
            "/etc/linux-rtx-vsr/extension"
            # Origin searches its compiled default profile for native hosts,
            # even with --user-data-dir. Bind the actual store file: the /etc
            # registry contains symlinks through /etc/static, absent in nixpak.
            [
              (toString vsrManifest)
              (sloth.concat' sloth.homeDir "/.config/BraveSoftware/Brave-Origin/NativeMessagingHosts/${vsrManifestName}")
            ]
            "/etc/misterdownloadmanager/extension"
            [
              (toString mdmManifest)
              (sloth.concat' sloth.homeDir "/.config/BraveSoftware/Brave-Origin/NativeMessagingHosts/${mdmManifestName}")
            ]
          ];
        };
    in
    utils.mkSandboxed (sandboxArgs // {
      inherit resourceLimits extraPerms;
    });

  # ── Instances ──────────────────────────────────────────────────────────────
  brave = mkBrave {
    name = "brave";
    displayName = "Brave (Secure)";
    configDir = "BraveSoftware/Brave-Origin-Nightly";
    wmClass = "brave-origin";
    extraBraveArgs = [
      "--load-extension=/etc/brave-warp-extension,/etc/linux-rtx-vsr/extension,/etc/misterdownloadmanager/extension"
    ];
  };

  hostProfile = "/home/${username}/.config/BraveSoftware/Brave-Origin-Nightly";
  legacyHostProfile = "/home/${username}/.config/BraveSoftware/Brave-Browser";
  privateProfile = "/var/lib/brave-private/.config/BraveSoftware/Brave-Browser";
in
{
  packages = [ brave rtxVsr ];

  module = {
    environment.etc."brave-warp-extension".source = warpExtension;
    environment.etc."linux-rtx-vsr/extension".source = "${rtxVsr}/share/linux-rtx-vsr/extension";
    environment.etc."linux-rtx-vsr/native-messaging-hosts/${vsrManifestName}".source = vsrManifest;
    environment.etc."misterdownloadmanager/extension".source = "${mdm}/share/misterdownloadmanager/extension-chromium";

    system.activationScripts.brave-host-profile-migration = {
      deps = [ "users" ];
      text = ''
        private_src=${pkgs.lib.escapeShellArg privateProfile}
        legacy_src=${pkgs.lib.escapeShellArg legacyHostProfile}
        dst=${pkgs.lib.escapeShellArg hostProfile}
        parent=$(${pkgs.coreutils}/bin/dirname "$dst")
        marker="$dst/.codex-profile-data-migrated-from-brave-browser"
        backup="$dst.pre-browser-data-migration"

        is_empty_dir() {
          [ -d "$1" ] && [ -z "$(${pkgs.findutils}/bin/find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]
        }

        ${pkgs.coreutils}/bin/install -d -m 0700 -o ${username} -g users "$parent"

        if [ -d "$private_src" ] && { [ ! -e "$dst" ] || is_empty_dir "$dst"; }; then
          if [ -e "$dst" ]; then
            ${pkgs.coreutils}/bin/rmdir "$dst"
          fi

          ${pkgs.coreutils}/bin/cp -a "$private_src" "$dst"
          ${pkgs.coreutils}/bin/chown -R ${username}:users "$dst"
          ${pkgs.coreutils}/bin/chmod 0700 "$dst"
        elif [ ! -e "$dst" ]; then
          ${pkgs.coreutils}/bin/install -d -m 0700 -o ${username} -g users "$dst"
        fi

        if [ -d "$legacy_src" ] && [ ! -e "$marker" ]; then
          if ${pkgs.procps}/bin/pgrep -u ${username} -x brave >/dev/null \
            || ${pkgs.procps}/bin/pgrep -u ${username} -f '(^|/)brave-origin( |$)' >/dev/null; then
            echo "brave profile data migration: Brave is running; close it and rebuild again to copy cookies/history safely."
          else
            if [ -d "$dst" ] && [ ! -e "$backup" ]; then
              ${pkgs.coreutils}/bin/cp -a "$dst" "$backup"
              ${pkgs.coreutils}/bin/chown -R ${username}:users "$backup"
            fi

            ${pkgs.rsync}/bin/rsync -a \
              --exclude='/Default/Preferences' \
              --exclude='/Default/Secure Preferences' \
              --exclude='/Local State' \
              --exclude='/SingletonCookie' \
              --exclude='/SingletonLock' \
              --exclude='/SingletonSocket' \
              --exclude='/Crashpad/' \
              --exclude='/BrowserMetrics/' \
              --exclude='/ShaderCache/' \
              --exclude='/GrShaderCache/' \
              --exclude='/DawnCache/' \
              --exclude='/Default/Cache/' \
              --exclude='/Default/Code Cache/' \
              --exclude='/Default/GPUCache/' \
              --exclude='/Default/ShaderCache/' \
              --exclude='/Default/GrShaderCache/' \
              --exclude='/Default/DawnCache/' \
              "$legacy_src/" "$dst/"

            ${pkgs.coreutils}/bin/touch "$marker"
            ${pkgs.coreutils}/bin/chown -R ${username}:users "$dst"
            ${pkgs.coreutils}/bin/chmod 0700 "$dst"
          fi
        fi
      '';
    };

    xdg.mime.defaultApplications = {
      "text/html" = "com.sandboxed.brave.desktop";
      "application/xhtml+xml" = "com.sandboxed.brave.desktop";
      "x-scheme-handler/http" = "com.sandboxed.brave.desktop";
      "x-scheme-handler/https" = "com.sandboxed.brave.desktop";
      "x-scheme-handler/about" = "com.sandboxed.brave.desktop";
      "x-scheme-handler/unknown" = "com.sandboxed.brave.desktop";
    };
  };

  brave-browser = brave;
}
