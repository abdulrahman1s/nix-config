{ pkgs, utils, sandboxedXdgUtils, inputs, username, ... }:

let
  braveOriginNightly =
    inputs.brave-previews.packages.${pkgs.stdenv.hostPlatform.system}.brave-origin-nightly;

  chromiumWaylandArgs = [
    "--enable-features=UseOzonePlatform,WaylandWindowDecorations,VaapiVideoDecoder,VaapiVideoEncoder,VaapiIgnoreDriverChecks"
    "--ozone-platform-hint=auto"
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
        "bluetooth"
        "u2f"
      ]
    ,
    }:
    let
      # --user-data-dir pinned to the bound config path; mkdir's $TMPDIR — see
      # nixpak singleton-socket comment, TMPDIR lives under XDG_RUNTIME_DIR so
      # every sandbox instance shares the ProcessSingleton dir.
      wrappedBrave = pkgs.writeShellScriptBin name ''
        ${pkgs.coreutils}/bin/mkdir -p "$TMPDIR"
        exec ${braveOriginNightly}/bin/brave-origin-nightly \
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
          ln -s ${braveOriginNightly}/share $out/share
        '';
      };

      sandboxArgs = {
        inherit
          name
          displayName
          configDir
          exportDesktopFiles
          extraBinNames
          presets
          ;
        package = bravePackage;
        binPath = "bin/${name}";
        homeBinds.rw = [
          { suffix = "/.pki/nssdb"; }
          { suffix = "/Downloads"; }
          { suffix = "/.local/share/applications"; }
          { suffix = "/.local/share/icons"; }
          { suffix = "/.config/mimeapps.list"; perms = "rw"; }
        ];
        extraPackages = [
          sandboxedXdgUtils
          pkgs.cosmic-files
          pkgs.brotab
        ];
      };

      # Share Chromium's tmp dir across sandbox invocations.
      extraPerms =
        { sloth, ... }:
        {
          bubblewrap.env.TMPDIR = sloth.concat' sloth.runtimeDir "/${name}-singleton-tmp";
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
  };

  hostProfile = "/home/${username}/.config/BraveSoftware/Brave-Origin-Nightly";
  legacyHostProfile = "/home/${username}/.config/BraveSoftware/Brave-Browser";
  privateProfile = "/var/lib/brave-private/.config/BraveSoftware/Brave-Browser";
in
{
  packages = [ brave ];

  module = {
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
            || ${pkgs.procps}/bin/pgrep -u ${username} -f '(^|/)brave-origin-nightly( |$)' >/dev/null; then
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
