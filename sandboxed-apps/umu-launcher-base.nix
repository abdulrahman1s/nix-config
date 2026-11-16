# Shared configuration for umu-launcher variants.
# Used by umu-launcher.nix (online) and umu-launcher-offline.nix (offline).
{ pkgs, utils }:

{ name
, extraBinNames ? [ ]
, enableNetwork ? true
}:

utils.mkSandboxed {
  package = pkgs.umu-launcher.override {
    # SteamRT discovers overlays through the FHS environment's Vulkan manifests.
    # Include both architectures for 32-bit games such as San Andreas.
    extraPkgs = p: [ p.mangohud ];
    extraProfile = ''
      # An unset overlay-disable switch must stay unset after clearEnv defaults.
      if [ -z "''${DISABLE_MANGOHUD:-}" ]; then
        unset DISABLE_MANGOHUD
      fi
    '';
  };
  inherit name extraBinNames;
  pathBinding = "dir";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "controller"
  ] ++ pkgs.lib.optionals enableNetwork [ "network" ];

  extraPerms =
    { sloth, ... }:
    {
      # MIT-SHM (X11 shared memory) passes SysV shm segment IDs between
      # client and X server; --unshare-ipc breaks that because the X server
      # can't attach to a segment from a different IPC namespace. Wine/DXVK
      # uses MIT-SHM via Xwayland, so the game errors out with
      # "BadValue ... X_ShmPutImage" without this.
      bubblewrap.shareIpc = true;

      bubblewrap.bind = {
        rw = [
          # /home/abdulrahman/Games/umu/umu-default
          (sloth.concat' sloth.homeDir "/.local/share/umu")
          # Preserve partial SteamRT downloads so interrupted updates can resume.
          (sloth.concat' sloth.homeDir "/.cache/umu")
          (sloth.concat' sloth.homeDir "/.local/share/Steam/compatibilitytools.d")
          (sloth.concat' sloth.homeDir "/.config/protonfixes")
          (sloth.concat' sloth.homeDir "/Games/umu")
        ];

        ro = [
          # Required by Wine/Proton for user identity lookup
          "/etc/passwd"
          "/etc/group"
          "/etc/nsswitch.conf"
          # The nested FHS environment requires /etc/zoneinfo. Bind the store
          # directory directly: the host symlink goes through absent /etc/static.
          [ "${pkgs.tzdata}/share/zoneinfo" "/etc/zoneinfo" ]
        ];

        # X11 socket for Xwayland. Niri opens both /tmp/.X11-unix/X0 and the
        # abstract @/tmp/.X11-unix/X0; the latter is netns-scoped, so under
        # --unshare-net (offline) only the filesystem socket reaches the sandbox.
        # Has to land via bind.dev because nixpak emits --dev-bind-try AFTER
        # --tmpfs /tmp (launch.nix:55-77); --ro-bind goes BEFORE and gets wiped
        # by the tmpfs. --dev-bind on a unix socket behaves like a plain bind.
        dev = [
          "/tmp/.X11-unix"
        ];
      };

      bubblewrap.env = {
        GST_DEBUG = "0";
        GAMEID = sloth.envOr "GAMEID" "umu-default";
        WINEPREFIX = sloth.envOr "WINEPREFIX" (sloth.concat [
          sloth.homeDir "/Games/umu/" (sloth.envOr "GAMEID" "umu-default")
        ]);
        # WINEDEBUG = "-all";

        # SECURITY: Shares home inside Pressure Vessel's nested container.
        # Safe here because our outer bubblewrap sandbox already restricts
        # which host paths are visible as "home".
        PRESSURE_VESSEL_SHARE_HOME = "1";
      } // pkgs.lib.genAttrs [
        # These are umu's documented launch inputs, often supplied as shell
        # assignments. Keep them when the shared sandbox clears credentials.
        "PROTONPATH" "STORE" "UMU_LOG"
        "PROTON_LOG" "PROTON_ENABLE_WAYLAND" "PROTON_USE_WINED3D"
        "PROTON_NO_ESYNC" "PROTON_NO_FSYNC" "DXVK_HUD"
        "DXVK_CONFIG_FILE" "VKD3D_CONFIG" "WINEDLLOVERRIDES"
      ] (key: pkgs.lib.mkDefault (sloth.envOr key ""))
      // pkgs.lib.optionalAttrs (!enableNetwork) {
        # Sandbox has no network: skip the per-launch steamrt3 update check,
        # which otherwise hangs trying to reach repo.steampowered.com.
        # Requires the runtime to already be installed in ~/.local/share/umu.
        UMU_RUNTIME_UPDATE = "0";
      };
    };
}
