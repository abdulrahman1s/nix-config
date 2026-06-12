# ============================================================================
# NixPak Sandbox Framework
# ============================================================================
#
# Base sandbox (always applied):
#   - Private /tmp (tmpfs)
#   - newSession (TIOCSTI protection)
#   - dieWithParent (cleanup on parent exit)
#   - Dummy machine-id (anti-fingerprinting)
#   - Read-only: fonts, SSL certs, D-Bus socket, icons, localtime, os-release,
#                resolv.conf, hosts
#   - Read-write: XDG_RUNTIME_DIR, ~/.config/<configDir>
#
# The wayland preset additionally provides (read-only):
#   - GNOME/GTK theming: dconf database, gtk-3.0, gtk-4.0 settings
#   - Fonts: user fonts + fontconfig overrides
#   - Theme data: system themes, icons, cursors, GSettings schemas
#   - Cursor: XCURSOR_THEME, XCURSOR_SIZE passthrough
#
# Available presets:
#   network       - Network namespace access
#   wayland       - Wayland display + GTK/GNOME theming, fonts, cursor
#   gpu           - GPU device nodes + driver paths (NVIDIA filtered at eval)
#   audio         - PipeWire socket + raw ALSA (/dev/snd)
#   controller    - Input devices (gamepads, etc.)
#   usb           - USB device enumeration
#   webcam        - V4L2 video capture devices (existing /dev/video* nodes)
#   bluetooth     - BlueZ D-Bus access (pair with `audio` for A2DP)
#   kvm           - /dev/kvm for hardware-accelerated virtualization
#   u2f           - hidraw for U2F/FIDO2 + pcscd socket for smart card
#   discovery     - Avahi/mDNS service discovery
#   portals       - D-Bus portal access (file picker, screen share, etc.)
#   notifications - Desktop notifications
#   systray       - System tray icon (StatusNotifier)
#   secrets       - Keyring/secrets service access
#
# Per-invocation dynamic bind:
#   pathBinding = "dir";  - For each arg that resolves to a real path, rw-bind
#                           its parent dir (or the dir itself if it's a dir).
#                           Sibling files remain visible — needed for apps
#                           with sidecars. Falls back to $PWD when no path
#                           arg resolves. Refuses /, $HOME, and ancestors of
#                           $HOME. Duplicate parents are deduplicated.
#   pathBinding = "file"; - For each arg that resolves to an existing FILE,
#                           rw-bind ONLY that file. Refuses dir args outright
#                           (strictest). With no resolving path arg, rw-binds
#                           /dev/null as a no-op and lands cwd at /. NOTE:
#                           inner cwd is not writable in file mode — apps
#                           that write sidecars next to the input
#                           (screenshots, .osd state, thumbnails) will fail.
#   Multi-path: every resolving arg gets bound, up to 16 distinct paths. Apps
#   like mpv playlists or file-manager bulk-opens just work. Apps with
#   `--input /a --output /b` get both ends bound. Args that don't resolve
#   (flags like `--foo`) are passed through unchanged.
#   Slots are exported as SANDBOX_PATH_0 .. SANDBOX_PATH_15 (unused slots
#   default to /dev/null in nixpak via sloth.envOr). Inside the sandbox the
#   slot env vars are blanked so paths don't leak into app env.
#   Tolerates RFC 8089 file:// variants: file:///path, file://localhost/path,
#   file:/path. Other-host or malformed forms (file://host/path) are skipped.
#   Not a preset — needs to wrap the entry binary, which presets (sandbox-
#   internal config) cannot do.
#
# The launcher itself lives in `./path-binding.nix` and is unit-tested in
# `../test-pathbinding.nix` via `nix flake check`.
#
# TODO: Consider bubblewrap.unshareAll = true for defense-in-depth.
# Requires auditing all presets to explicitly re-enable needed namespaces.
# ============================================================================
{ pkgs, nixpak, username ? null }:

let
  pathBindingLib = import ./path-binding.nix { inherit pkgs; };
  inherit (pathBindingLib) maxPathSlots mkPathBindingLauncher;

  # mkSandboxed is defined further down in this `let` block; Nix lazy
  # bindings make the forward reference fine. The wrapper-side function
  # consumes mkSandboxed as a callable, not as a derivation, so there's
  # no eval-time cycle.
  mkPrivateUserSandbox = import ./private-user.nix { inherit pkgs mkSandboxed; };

  mkNixPak = nixpak.lib.nixpak {
    inherit (pkgs) lib;
    inherit pkgs;
  };

  # Anti-fingerprinting: all sandboxed apps see a zeroed machine-id
  dummyMachineId = pkgs.writeText "machine-id" "00000000000000000000000000000000\n";

  mkSandboxed =
    { package
    , name ? package.pname
    , executableName ? package.meta.mainProgram or package.pname or name
    , configDir ? name
    , binPath ? "bin/${executableName}"
    , extraPerms ? { }
    , extraPackages ? [ ]
    , presets ? [ ]
    , exportDesktopFiles ? true
    , extraBinNames ? [ ]
    , resourceLimits ? null
    , displayName ? null
    , homeBinds ? { rw = [ ]; ro = [ ]; }
      # Host-home bind list: `{ rw, ro }` of `{ suffix; perms?; }`
      # entries. Suffix is `$HOME`-relative (e.g. `/Downloads`).
      # Each entry becomes a bwrap bind via the cross-uid helper
      # (mkHomeBindEntry below) AND is exposed via passthru.homeBinds
      # so outer wrappers (mkPrivateUserSandbox) can derive ACL grants
      # from the same declaration. perms is interpreted by the ACL
      # consumer; this builder doesn't read it.
    , outerBinPath ? null # Override the binary path baked into generated .desktop files.
      # When wrapped by another derivation (e.g. mkPrivateUserSandbox)
      # the .desktop should point at the outer launcher, not at
      # this sandbox's $out/bin/${name}. Pass the outer launcher
      # store path here and the .desktop's `Exec=` will use it.
    , wmClass ? null # Override for apps that set their own window class (e.g. Java)
    , sharePid ? false  # Share the host PID namespace. Required for apps that
      # use a PID-based singleton lock in a shared user-data
      # dir (Chromium's SingletonLock: a second invocation
      # does kill(pid, 0) to check liveness; in its own pidns
      # that PID is invisible, so it clobbers the lock the
      # first instance still holds and shows "profile in use").
      # nixpak hardcodes --unshare-pid in launch.nix; this
      # opts out by post-processing the generated bwrap args
      # JSON to strip that flag.
    , pathBinding ? null  # null | "dir" | "file" — narrow the rw bind dynamically.
      # "dir":  if $1 is a file, bind its parent directory.
      #         if $1 is a directory, bind it as-is.
      #         (Default for tools that need sibling files —
      #         games with sidecar assets, players with subtitles.)
      #         Refuses /, $HOME, and ancestors of $HOME.
      # "file": if $1 is a file, bind ONLY that file. Strictest:
      #         refuses dir args outright; no-arg launch binds
      #         /dev/null as a no-op. NOTE: inner cwd isn't
      #         writable — apps that write sidecars next to the
      #         input (screenshots, .osd, thumbnails) will fail.
      # Single-path: picks the LAST arg that resolves to an
      # existing path. Apps with multiple paths
      # (`--input /a --output /b`) only get one bound. See
      # `path-binding.nix` for full semantics.
      # In both modes, the launcher exports SANDBOX_PATH and
      # the sandbox rw-binds (sloth.env "SANDBOX_PATH").
      # Cannot be a preset: presets configure sandbox internals,
      # but this needs to wrap the entry binary itself.
    }:
    let
      # Use provided displayName or fallback to package description/name + (Secure)
      finalDisplayName =
        if displayName != null then displayName else "${package.meta.description or name} (Secure)";

      # If extra packages are requested, create a combined environment
      envPackage =
        if extraPackages == [ ] then
          package
        else
          pkgs.symlinkJoin {
            name = "${name}-env";
            paths = [ package ] ++ extraPackages;
          };

      # Host-home bind helper. When `username` is set in the framework
      # (the configuration's main user), home-relative binds use the
      # asymmetric `[hostPath sandboxPath]` form so a private system user
      # running the sandbox still finds the data under `$HOME` inside.
      # With `username = null`, falls back to the symmetric in-sandbox path.
      mkHomeBindEntry = sloth: suffix:
        if username == null then
          sloth.concat' sloth.homeDir suffix
        else
          [ "/home/${username}${suffix}" (sloth.concat' sloth.homeDir suffix) ];

      # Host-home bind entries contributed by built-in presets. Centralised so
      # the preset module emits them via `mkHomeBindEntry` AND `passthru.homeBinds`
      # advertises them to outer wrappers (e.g. mkPrivateUserSandbox) that need
      # ACL grants on the host paths. Single source of truth: change here only.
      presetHomeBinds = {
        wayland.ro = map (suffix: { inherit suffix; }) [
          "/.config/dconf"
          "/.config/gtk-3.0"
          "/.config/gtk-4.0"
          "/.local/share/fonts"
          "/.config/fontconfig"
          "/.local/share/themes"
        ];
      };

      # Normalise caller-provided homeBinds: function defaults only fire when
      # the whole `homeBinds` attr is absent, so callers passing `{ rw = […]; }`
      # alone would leave `.ro` undefined.
      callerHomeBinds = {
        rw = homeBinds.rw or [ ];
        ro = homeBinds.ro or [ ];
      };

      # Merged caller + active-preset home binds. Consumed by passthru.homeBinds
      # below; outer wrappers read it for ACL granting + traversal-dir derivation.
      effectiveHomeBinds = {
        rw = callerHomeBinds.rw
          ++ pkgs.lib.concatLists
          (map (p: presetHomeBinds.${p}.rw or [ ]) presets);
        ro = callerHomeBinds.ro
          ++ pkgs.lib.concatLists
          (map (p: presetHomeBinds.${p}.ro or [ ]) presets);
      };

      # --- PERMISSION PRESETS ---
      availablePresets = {
        # -- Sandbox capabilities --
        network = {
          bubblewrap.network = true;
        };

        wayland =
          { sloth, ... }:
          {
            bubblewrap.env = {
              NIXOS_OZONE_WL = "1"; # Chromium/Electron native Wayland
              XDG_SESSION_TYPE = "wayland";
              WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";

              # Toolkit hints — prefer Wayland, fall back to X11/xcb if
              # the app can't talk Wayland. Without these, Qt apps stay
              # on xcb (blurry HiDPI, no fractional scaling) and
              # Firefox/Thunderbird default to X11 too.
              GDK_BACKEND = "wayland,x11";
              QT_QPA_PLATFORM = "wayland;xcb";
              MOZ_ENABLE_WAYLAND = "1";

              # Cursor — pass through host settings so sandboxed apps
              # pick up the correct cursor theme and size.
              # envOr: use host value if set, otherwise fall back to GNOME defaults.
              XCURSOR_THEME = sloth.envOr "XCURSOR_THEME" "default";
              XCURSOR_SIZE = sloth.envOr "XCURSOR_SIZE" "24";
            };

            # Home-path entries (dconf, gtk-3.0/4.0, fonts, fontconfig, themes)
            # come from `presetHomeBinds.wayland.ro` above so they're a single
            # source of truth shared with passthru.homeBinds. Cross-uid mapped
            # via mkHomeBindEntry when `username` is set so a private system
            # user running the sandbox still finds them at $HOME-relative paths.
            bubblewrap.bind.ro =
              (map
                (entry: mkHomeBindEntry sloth entry.suffix)
                presetHomeBinds.wayland.ro)
              ++ [
                # NixOS system profile theme/icon data — same store path for
                # every uid, no ACL needed.
                "/run/current-system/sw/share/themes"
                "/run/current-system/sw/share/icons"
                "/run/current-system/sw/share/glib-2.0"
              ];
          };

        x11 =
          { sloth, ... }:
          {
            bubblewrap.env = {
              DISPLAY = sloth.env "DISPLAY";
              XDG_SESSION_TYPE = "x11";
              NIXOS_OZONE_WL = "0";
            };

            bubblewrap.bind.ro = [
              "/tmp/.X11-unix"
            ];
          };

        controller = {
          bubblewrap.bind.dev = [
            "/dev/uinput" # Write access required to inject input events
            "/dev/input"
          ];
        };

        gpu = {
          bubblewrap.bind = {
            # NVIDIA nodes only exist when the proprietary driver is
            # loaded; nixpak tolerates missing sources at bind time
            # (silently skips, doesn't error), so listing them
            # unconditionally is portable across NVIDIA/non-NVIDIA hosts.
            dev = [
              "/dev/dri"
              "/dev/nvidia0"
              "/dev/nvidiactl"
              "/dev/nvidia-modeset"
              "/dev/nvidia-uvm"
              "/dev/nvidia-uvm-tools"
            ];

            ro = [
              "/run/opengl-driver"
              "/run/opengl-driver-32"
              "/usr/share/drirc.d"

              # Only expose the /sys subtrees that GPU drivers actually read.
              # Mesa/libdrm needs: /sys/dev/char, /sys/class/drm, /sys/bus/pci
              # NVIDIA driver needs: /sys/bus/pci, /sys/devices (PCI tree walk)
              "/sys/bus/pci" # PCI bus enumeration for GPU detection
              "/sys/class/drm" # DRM device class
              "/sys/dev/char" # Device number → sysfs path mapping
              "/sys/devices" # Full device tree (needed for driver init)
              "/sys/class/hwmon" # NVIDIA driver looks for fan/temp sensors here, but it's not critical
            ];
          };
        };

        audio =
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.runtimeDir "/pipewire-0")
            ];
            # Bind the whole /dev/snd, not just seq. Apps that bypass
            # PipeWire and open raw ALSA (/dev/snd/pcm*, controlC*) —
            # many games and older audio tools — need the device nodes
            # directly. seq alone covered MIDI but not playback.
            bubblewrap.bind.dev = [
              "/dev/snd"
            ];
          };

        usb = {
          bubblewrap.bind = {
            dev = [
              "/dev/bus/usb" # Actual USB device access (read/write/ioctl)
            ];
            ro = [
              "/sys/bus/usb"
              "/sys/dev"
              "/run/udev"
            ];
          };
        };

        discovery = {
          bubblewrap.bind.rw = [
            "/run/avahi-daemon/socket" # connect() to Unix socket requires write on the mount
          ];
        };

        # -- D-Bus service access --
        portals =
          { sloth, ... }:
          {
            dbus.policies = {
              "org.freedesktop.DBus" = "talk";
              "org.freedesktop.portal.*" = "talk"; # File picker, screen share, open URI, etc.
              "org.gtk.vfs" = "talk";
              "org.gtk.vfs.*" = "talk";
            };

            # Keep the document portal FUSE mount visible inside the sandbox.
            # File transfers over clipboard/drag-and-drop use this path.
            bubblewrap.bind.rw = pkgs.lib.mkAfter [
              (sloth.concat' sloth.runtimeDir "/doc")
              (sloth.concat' sloth.runtimeDir "/gvfsd")
            ];
          };

        notifications = {
          dbus.policies = {
            "org.freedesktop.Notifications" = "talk";
          };
        };

        systray = {
          dbus.policies = {
            "org.kde.StatusNotifierWatcher" = "talk";
          };
        };

        secrets = {
          dbus.policies = {
            "org.freedesktop.secrets" = "talk"; # System keyring integration
          };
        };

        # V4L2 video capture: /dev/video<0..9> device nodes + sysfs
        # class for enumeration. Listed unconditionally — nixpak skips
        # missing sources, and hotplug works as long as the device is
        # present before the app launches (bind mounts can't be added
        # to a running namespace).
        webcam = {
          bubblewrap.bind = {
            dev = map (i: "/dev/video" + toString i) (pkgs.lib.lists.range 0 9);
            ro = [
              "/sys/class/video4linux"
            ];
          };
        };

        # BlueZ D-Bus surface. Pair with the `audio` preset for A2DP
        # playback — PipeWire bridges Bluetooth audio over the standard
        # pipewire-0 socket, so no extra device binds are needed.
        bluetooth = {
          dbus.policies = {
            "org.bluez" = "talk";
          };
        };

        # /dev/kvm for hardware-accelerated virtualization (QEMU,
        # Crosvm, etc.). User must already be in the `kvm` group on
        # the host — this preset only forwards the device node.
        kvm = {
          bubblewrap.bind.dev = [
            "/dev/kvm"
          ];
        };

        # Security keys: U2F/FIDO2 via /dev/hidraw<0..20> (browsers,
        # libfido2) and smart card / OpenPGP card mode via pcscd's
        # Unix socket. Stable proxy nodes let devices appear and disappear
        # after the sandbox starts; each node retains its kernel major/minor.
        u2f = {
          bubblewrap.bind = {
            dev = map
              (i: [
                "/dev/hidraw-proxy/hidraw${toString i}"
                "/dev/hidraw${toString i}"
              ])
              (pkgs.lib.lists.range 0 20);
            ro = [
              "/sys/class/hidraw"
              "/sys/bus/hid"
              # libudev walks /sys/devices to enumerate HID nodes;
              # without it, udev_enumerate_* returns nothing and most
              # FIDO libraries silently fail to find the key.
              "/sys/devices"
              "/run/udev/data"
            ];
            rw = [
              "/run/pcscd"
            ];
          };
        };
      };

      # Validate preset names and select them
      validPresetNames = builtins.attrNames availablePresets;
      presetValidation = map
        (p:
          assert pkgs.lib.assertMsg
            (builtins.hasAttr p availablePresets)
            "mkSandboxed (${name}): unknown preset '${p}'. Available presets: ${builtins.concatStringsSep ", " validPresetNames}";
          null
        )
        presets;
      activePresets = builtins.seq presetValidation (map (p: availablePresets.${p}) presets);

      appId = "com.sandboxed.${name}";
      finalWmClass = if wmClass != null then wmClass else appId;

      sandbox = mkNixPak {
        config =
          { ... }:
          {
            imports = [
              (
                { sloth, ... }:
                {
                  app.package = envPackage;
                  app.binPath = binPath;
                  flatpak.appId = appId;

                  dbus.policies = {
                    "${appId}" = "own";
                    "${appId}.*" = "own";
                  };

                  # --- SANDBOX HARDENING ---
                  bubblewrap.newSession = true; # Prevent TIOCSTI terminal injection
                  bubblewrap.dieWithParent = true; # Kill sandbox when parent exits
                  bubblewrap.tmpfs = [ "/tmp" ]; # Private /tmp per sandbox

                  # Offline by default. nixpak's own default is `true`, so without
                  # this an app that omits the "network" preset silently keeps
                  # host network. Use mkDefault so the "network" preset (which
                  # sets bubblewrap.network = true) can override.
                  bubblewrap.network = pkgs.lib.mkDefault false;

                  # Base binds that everyone needs
                  bubblewrap.bind.ro = [
                    [ "${dummyMachineId}" "/etc/machine-id" ] # Dummy (anti-fingerprint)
                    "/etc/os-release"
                    "/etc/localtime" # Ensure time matches host
                    "/etc/resolv.conf" # DNS resolution
                    "/etc/hosts" # Hostname resolution

                    "/etc/fonts"
                    "/etc/ssl/certs"
                    "/run/dbus"
                    (mkHomeBindEntry sloth "/.icons")
                  ];

                  bubblewrap.bind.rw = [
                    (sloth.env "XDG_RUNTIME_DIR")
                    (sloth.concat' sloth.homeDir "/.config/${configDir}")
                  ];
                }
              )
              extraPerms
              # Caller-supplied homeBinds (host-home rw/ro). Single declaration
              # → bwrap binds here, ACL grants via passthru.homeBinds.
              (
                { sloth, ... }:
                {
                  bubblewrap.bind.rw =
                    map (e: mkHomeBindEntry sloth e.suffix) callerHomeBinds.rw;
                  bubblewrap.bind.ro =
                    map (e: mkHomeBindEntry sloth e.suffix) callerHomeBinds.ro;
                }
              )
            ]
            ++ activePresets
            ++ pkgs.lib.optional (pathBinding != null) (
              { sloth, ... }:
              {
                # Fixed-size slot list. The launcher exports
                # SANDBOX_PATH_<i> for each candidate; unused slots
                # resolve to /dev/null (a no-op rw-bind) via envOr.
                bubblewrap.bind.rw = builtins.genList
                  (i: sloth.envOr "SANDBOX_PATH_${toString i}" "/dev/null")
                  maxPathSlots;

                # Don't leak the bound paths into the inner app's env.
                # The launcher's exports are what bwrap resolves
                # sloth.envOr against at spawn; blanking them here
                # strips the values from anything bwrap exec's.
                bubblewrap.env = builtins.listToAttrs (builtins.genList
                  (i: { name = "SANDBOX_PATH_${toString i}"; value = ""; })
                  maxPathSlots);
              }
            );
          };
      };


      # nixpak's launcher script bakes BUBBLEWRAP_ARGS to a /nix/store JSON via
      # makeWrapper's `--set`, so we can't override it from the outer env. Instead,
      # produce a sibling derivation that copies the launcher, filters the JSON,
      # and rewrites the path. See the `sharePid` arg docstring above.
      script =
        if sharePid then
          pkgs.runCommandLocal "${name}-share-pid"
            {
              nativeBuildInputs = [ pkgs.jq ];
            } ''
            cp -r ${sandbox.config.script} $out
            chmod -R +w $out

            wrapper=$out/${binPath}
            origJson=$(${pkgs.gnugrep}/bin/grep -oP "BUBBLEWRAP_ARGS='\K[^']+" "$wrapper")
            if [ -z "$origJson" ]; then
              echo "share-pid: could not extract BUBBLEWRAP_ARGS from $wrapper" >&2
              exit 1
            fi

            patchedJson=$out/bwrap-args-share-pid.json
            jq 'map(select(. != "--unshare-pid"))' "$origJson" > "$patchedJson"

            substituteInPlace "$wrapper" \
              --replace-fail "BUBBLEWRAP_ARGS='$origJson'" "BUBBLEWRAP_ARGS='$patchedJson'"
          ''
        else sandbox.config.script;

      # Resource-limited wrapper via systemd-run (innermost wrapper if present).
      resourceWrapper =
        if resourceLimits != null then
          pkgs.writeShellScript "${name}-resource-limited" ''
            exec ${pkgs.systemd}/bin/systemd-run --user --scope --collect --same-dir \
              --unit="${name}-sandbox-$$" \
              -p CPUQuota=${resourceLimits.cpu} \
              -p MemoryMax=${resourceLimits.mem} \
              --description="${name} (Restricted)" \
              ${script}/bin/${executableName} "$@"
          ''
        else null;

      # The "inner entry": bwrap script, or the resource-limit wrapper around it.
      innerEntry =
        if resourceWrapper != null then "${resourceWrapper}"
        else "${script}/bin/${executableName}";

      # Path-binding launcher (outermost): see path-binding.nix.
      pathBindingLauncher =
        assert pkgs.lib.assertMsg
          (pathBinding == null || pathBinding == "dir" || pathBinding == "file")
          "mkSandboxed (${name}): pathBinding must be null, \"dir\", or \"file\" (got: ${builtins.toJSON pathBinding})";
        if pathBinding != null
        then mkPathBindingLauncher { inherit name pathBinding innerEntry; }
        else null;

      finalEntry =
        if pathBindingLauncher != null then "${pathBindingLauncher}" else innerEntry;

    in
    pkgs.runCommand "${name}-sandboxed"
      {
        nativeBuildInputs = [ pkgs.desktop-file-utils ];
        passthru.homeBinds = effectiveHomeBinds;
      }
      ''
        mkdir -p $out/bin
        ln -s ${finalEntry} $out/bin/${name}

        for extraBin in ${toString extraBinNames}; do
          ln -s $out/bin/${name} $out/bin/$extraBin
        done

        if ${pkgs.lib.boolToString exportDesktopFiles} && [ -d "${package}/share" ]; then
          mkdir -p $out/share
          if [ -d "${package}/share/icons" ]; then
            ln -s ${package}/share/icons $out/share/icons
          fi
          if [ -d "${package}/share/applications" ]; then
            mkdir -p $out/share/applications
            sanitize_dir="$(mktemp -d)"
            for f in ${package}/share/applications/*.desktop; do
              # Skip portal/duplicate entries marked as hidden
              if grep -q '^NoDisplay=true' "$f"; then
                continue
              fi

              # Strip non-spec keys from [Desktop Action ...] groups. The
              # freedesktop spec only permits Name, GenericName, Comment, Icon,
              # Exec, and X-* keys there; some upstream files (e.g. Brave
              # nightly) include StartupWMClass, which makes desktop-file-install
              # refuse the file.
              sanitized="$sanitize_dir/$(basename "$f")"
              awk '
                /^\[Desktop Action / { in_action=1; print; next }
                /^\[/                { in_action=0; print; next }
                in_action && /^[A-Za-z]/ && !/^(Name|GenericName|Comment|Icon|Exec|X-)/ { next }
                { print }
              ' "$f" > "$sanitized"

              # Name desktop file after the appId so the DE matches it to the Wayland app_id
              target="$out/share/applications/${appId}.desktop"
              desktop-file-install \
                --dir="$out/share/applications" \
                --set-key=Exec --set-value="${if outerBinPath != null then outerBinPath else "$out/bin/${name}"} %u" \
                --set-key=Name --set-value="${finalDisplayName}" \
                --set-key=StartupWMClass --set-value="${finalWmClass}" \
                --set-key=StartupNotify --set-value=true \
                "$sanitized"
              mv "$out/share/applications/$(basename "$f")" "$target"
            done
          fi
        fi
      '';
in
{
  inherit mkPathBindingLauncher mkSandboxed mkPrivateUserSandbox;
}
