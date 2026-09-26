{ pkgs, utils, sandboxedXdgUtils, inputs, ... }:

let
  serviceVersion = "0.1.21";
  serverVersion = "4.20.17";

  braveOrigin = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.brave-origin;

  # Use Stremio's official prebuilt service package, but keep only the web
  # streaming server and artwork. The Rust tray application is unnecessary for
  # this web-only launcher and would otherwise need to be compiled by nixpkgs.
  stremioServiceAssets = pkgs.stdenvNoCC.mkDerivation {
    pname = "stremio-web-service-assets";
    version = serviceVersion;

    src = pkgs.fetchurl {
      url = "https://github.com/Stremio/stremio-service/releases/download/v${serviceVersion}/stremio-service_amd64.deb";
      hash = "sha256-fVXdr8RtaDtWxyCFWj+MjLfKwdzoFzFL+r4JiuWGjGc=";
    };

    nativeBuildInputs = [ pkgs.dpkg ];

    unpackPhase = ''
      runHook preUnpack
      dpkg-deb -x "$src" source
      runHook postUnpack
    '';

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      install -Dm644 source/usr/share/stremio-service/server.js \
        "$out/share/stremio-service/server.js"
      install -Dm644 source/usr/share/icons/hicolor/scalable/apps/com.stremio.service.svg \
        "$out/share/icons/hicolor/scalable/apps/stremio.svg"
      install -Dm644 source/usr/share/licenses/stremio-service/LICENSE.md \
        "$out/share/licenses/stremio-service/LICENSE.md"

      runHook postInstall
    '';

    meta = {
      description = "Official Stremio streaming-server assets for Stremio Web";
      homepage = "https://github.com/Stremio/stremio-service";
      license = with pkgs.lib.licenses; [ gpl2Only unfree ];
      platforms = [ "x86_64-linux" ];
      sourceProvenance = with pkgs.lib.sourceTypes; [ binaryNativeCode ];
    };
  };

  stremioLauncher = pkgs.writeShellApplication {
    name = "stremio";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      nodejs
      procps
    ];
    text = ''
      config_dir="$HOME/.config/stremio-web"
      cache_dir="$HOME/.cache/stremio-web"
      local_state="$config_dir/Local State"
      server_pid=""

      mkdir -p "$config_dir" "$cache_dir" "$HOME/.stremio-server" "$HOME/Downloads"

      # Brave Origin's startup gate is independent of Chromium's first-run
      # switches. Accept Linux's free tier in this dedicated app profile so the
      # gate cannot replace Stremio on every launch.
      if ! jq --exit-status \
        '.brave.origin.free_tier_accepted == true or .brave.origin.purchase_validated == true' \
        "$local_state" >/dev/null 2>&1; then
        local_state_tmp=$(mktemp "$config_dir/.local-state.XXXXXX")
        if [ -s "$local_state" ]; then
          jq '.brave.origin.free_tier_accepted = true' \
            "$local_state" > "$local_state_tmp"
        else
          jq --null-input \
            '{ brave: { origin: { free_tier_accepted: true } } }' \
            > "$local_state_tmp"
        fi
        mv "$local_state_tmp" "$local_state"
      fi

      cleanup() {
        if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
          kill "$server_pid" 2>/dev/null || true
          wait "$server_pid" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT HUP INT TERM

      # Reuse an already-running server when a second launcher window opens.
      if ! curl --silent --output /dev/null --connect-timeout 0.2 --max-time 0.5 \
        http://127.0.0.1:11470/; then
        export FFMPEG_BIN=${pkgs.jellyfin-ffmpeg}/bin/ffmpeg
        export FFPROBE_BIN=${pkgs.jellyfin-ffmpeg}/bin/ffprobe
        export NODE_ENV=production
        export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

        node ${stremioServiceAssets}/share/stremio-service/server.js &
        server_pid=$!

        # Give Stremio Web a live streaming endpoint on its first probe.
        for _attempt in $(seq 1 50); do
          if curl --silent --output /dev/null --connect-timeout 0.2 --max-time 0.5 \
            http://127.0.0.1:11470/; then
            break
          fi
          if ! kill -0 "$server_pid" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
      fi

      target_url=https://web.stremio.com
      case "''${1-}" in
        stremio://*)
          addon_url="https://''${1#stremio://}"
          encoded_addon=$(jq -nr --arg value "$addon_url" '$value | @uri')
          target_url="https://web.stremio.com/#/addons?addon=$encoded_addon"
          ;;
      esac

      ${braveOrigin}/bin/brave-origin \
        --app="$target_url" \
        --class=stremio \
        --name=stremio \
        --user-data-dir="$config_dir" \
        --disk-cache-dir="$cache_dir" \
        --disable-background-mode \
        --no-first-run \
        --no-default-browser-check \
        --enable-features=UseOzonePlatform,WaylandWindowDecorations,VaapiVideoDecoder,VaapiVideoEncoder,VaapiIgnoreDriverChecks \
        --ozone-platform-hint=auto \
        --ignore-gpu-blocklist \
        --enable-gpu-rasterization \
        --enable-zero-copy
    '';
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "stremio";
    desktopName = "Stremio";
    comment = "Stremio Web with the local streaming service";
    exec = "stremio %U";
    icon = "stremio";
    startupWMClass = "stremio";
    categories = [
      "AudioVideo"
      "Video"
      "Player"
      "TV"
    ];
    mimeTypes = [ "x-scheme-handler/stremio" ];
  };

  stremioWeb = pkgs.symlinkJoin {
    name = "stremio-web-${serverVersion}";
    paths = [
      stremioLauncher
      stremioServiceAssets
      desktopItem
    ];
    meta = {
      description = "Sandboxed Stremio Web client with its local streaming service";
      homepage = "https://web.stremio.com";
      license = with pkgs.lib.licenses; [ gpl2Only unfree ];
      mainProgram = "stremio";
      platforms = [ "x86_64-linux" ];
    };
  };
in
utils.mkSandboxed {
  package = stremioWeb;
  name = "stremio";
  displayName = "Stremio";
  configDir = "stremio-web";
  wmClass = "stremio";
  extraPackages = [
    sandboxedXdgUtils
    pkgs.cosmic-files
  ];
  presets = [
    "network"
    "wayland"
    "audio"
    "gpu"
    "portals"
    "notifications"
    "secrets"
    "mpris"
  ];
  homeBinds.rw = [
    { suffix = "/.cache/stremio-web"; }
    { suffix = "/.pki/nssdb"; }
    { suffix = "/.stremio-server"; }
    { suffix = "/Downloads"; }
  ];
  extraPerms =
    { sloth, ... }:
    {
      bubblewrap.env = {
        XDG_CONFIG_HOME = sloth.concat' sloth.homeDir "/.config/stremio-web";
        XDG_CACHE_HOME = sloth.concat' sloth.homeDir "/.cache/stremio-web";
        MANGOHUD = "0";
        MANGOHUD_DLSYM = "0";
        SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      };

      bubblewrap.bind.rw = [
        (sloth.concat' sloth.runtimeDir "/discord-ipc-0")
      ];
    };
}
