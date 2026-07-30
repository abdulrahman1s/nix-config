{ lib, pkgs, config, inputs, username, ... }:
let
  lactSrc = pkgs.fetchFromGitHub {
    owner = "ilya-zlobintsev";
    repo = "LACT";
    tag = "v0.9.1";
    hash = "sha256-/b5Cfexi/RtE3DkON5J3dc4aEX6aLZvIcAhsg6Kdv7M=";
  };
  lact = pkgs.lact.overrideAttrs (old: {
    version = "0.9.1";
    src = lactSrc;
    buildInputs = builtins.map
      (input: if input == pkgs.libdisplay-info then libdisplay-info_0_3 else input)
      (old.buildInputs or [ ]);
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      pname = "lact";
      version = "0.9.1";
      src = lactSrc;
      hash = "sha256-XV37VRbCaxySMgEqXmIA0TUpI9uR+6jGOzdMlEfWxDw=";
    };
    # v0.9.1's apply_settings test mounts a FUSE mock sysfs; /dev/fuse is absent in Nix builds.
    checkFlags = [ "--skip" "tests::apply_settings" ];
  });

  # Niri 26.04 and LACT 0.9.1 use Rust bindings that reject libdisplay-info 0.4.
  # Replace this local package with pkgs.libdisplay-info_0_3 once nixpkgs includes
  # https://github.com/NixOS/nixpkgs/commit/c088236389bd2631050f833a7c33267b48a904a6.
  libdisplay-info_0_3 = pkgs.libdisplay-info.overrideAttrs (
    finalAttrs: _: {
      version = "0.3.0";
      src = pkgs.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "emersion";
        repo = "libdisplay-info";
        rev = finalAttrs.version;
        hash = "sha256-nXf2KGovNKvcchlHlzKBkAOeySMJXgxMpbi5z9gLrdc=";
      };
    }
  );
  niri = pkgs.niri.override { libdisplay-info = libdisplay-info_0_3; };

  rtx5090Id = "10DE:2B85-196E:1431-0000:0a:00.0";

  # PNY RTX 5090 LACT/NvAPI table captured with LACT v0.9.1 + NVIDIA 595.84.
  # LACT exposes 127 editable NVIDIA VF points. Voltage is immutable on NVIDIA;
  # LACT applies frequency offsets at these voltage-indexed points.
  # Stock anchors: 940mV=2490MHz, 950mV=2610MHz, 1000mV=2782MHz,
  # 1010mV=2805MHz, 1185mV=3150MHz.
  #
  # How the flat-curve undervolt works: mkRtx5090FlatCurve pins every point from
  # the chosen floor upward to one target clock. The card then reaches that clock
  # at the LOWEST voltage on the curve that yields it (the floor), and can't climb
  # past it. Because of GPU Boost 5.0 droop, the *effective* in-game voltage runs
  # ~40-60mV BELOW the floor — so a 950mV floor settles near ~900mV in practice,
  # which is exactly the community daily sweet spot. The floors below were already
  # well placed; the previous targets just left a lot of clock on the table.
  rtx5090Vf940Plus = {
    "78" = 940;
    "79" = 945;
    "80" = 950;
    "81" = 960;
    "82" = 965;
    "83" = 970;
    "84" = 975;
    "85" = 985;
    "86" = 990;
    "87" = 995;
    "88" = 1000;
    "89" = 1010;
    "90" = 1015;
    "91" = 1020;
    "92" = 1025;
    "93" = 1035;
    "94" = 1040;
    "95" = 1045;
    "96" = 1050;
    "97" = 1060;
    "98" = 1065;
    "99" = 1070;
    "100" = 1075;
    "101" = 1085;
    "102" = 1090;
    "103" = 1095;
    "104" = 1100;
    "105" = 1110;
    "106" = 1115;
    "107" = 1120;
    "108" = 1125;
    "109" = 1135;
    "110" = 1140;
    "111" = 1145;
    "112" = 1150;
    "113" = 1160;
    "114" = 1165;
    "115" = 1170;
    "116" = 1175;
    "117" = 1185;
    "118" = 1190;
    "119" = 1195;
    "120" = 1200;
    "121" = 1210;
    "122" = 1215;
    "123" = 1220;
    "124" = 1225;
    "125" = 1235;
    "126" = 1240;
  };
  rtx5090Vf950Plus = builtins.removeAttrs rtx5090Vf940Plus [ "78" "79" ];
  # Floor at 975mV (index 84): drop 950/960/965/970 from the 950+ band.
  rtx5090Vf975Plus = builtins.removeAttrs rtx5090Vf950Plus [ "80" "81" "82" "83" ];
  rtx5090Vf1000Plus = builtins.removeAttrs rtx5090Vf950Plus [
    "80"
    "81"
    "82"
    "83"
    "84"
    "85"
    "86"
    "87"
  ];
  mkRtx5090FlatCurve = clockspeed: voltages:
    builtins.mapAttrs (_: voltage: { inherit clockspeed voltage; }) voltages;
  rtx5090FanCurves = {
    stock = {
      "40" = 0.30;
      "50" = 0.35;
      "60" = 0.50;
      "70" = 0.75;
      "80" = 1.00;
    };
    overclock = {
      "40" = 0.35;
      "50" = 0.45;
      "60" = 0.60;
      "70" = 0.85;
      "78" = 1.00;
    };
    performance = {
      "40" = 0.32;
      "50" = 0.40;
      "60" = 0.55;
      "70" = 0.78;
      "80" = 1.00;
    };
    balanced = {
      "40" = 0.30;
      "50" = 0.35;
      "62" = 0.48;
      "74" = 0.68;
      "83" = 1.00;
    };
    quiet = {
      "40" = 0.30;
      "52" = 0.33;
      "64" = 0.44;
      "76" = 0.62;
      "84" = 1.00;
    };
    eco = {
      "40" = 0.30;
      "55" = 0.33;
      "67" = 0.42;
      "78" = 0.58;
      "85" = 1.00;
    };
  };
  mkRtx5090FanControl = curve: {
    fan_control_enabled = true;
    fan_control_settings = {
      mode = "curve";
      static_speed = 0.5;
      temperature_key = "edge";
      interval_ms = 500;
      inherit curve;
      spindown_delay_ms = 5000;
      change_threshold = 2;
      auto_threshold = 50;
    };
  };
  mkLactConfig = settings:
    pkgs.runCommand "lact-config.yaml" { } ''
      ${pkgs.gnused}/bin/sed -E "s/^([[:space:]]*)'([0-9]+)':/\1\2:/" \
        ${(pkgs.formats.yaml { }).generate "lact-config.raw.yaml" settings} > $out
    '';

  # PR #528 moved linux-wallpaperengine's surface from the BACKGROUND to the BOTTOM
  # wlr-layer (a KDE Plasma repaint fix), which makes niri clone it into every
  # overview workspace card. PR #585 re-added a `--layer` flag; pin past it and
  # append `--layer background` so the companion `place-within-backdrop` layer-rule
  # in config/niri/rules.kdl folds the wallpaper into the backdrop.
  linux-wallpaperengine-niri = pkgs.linux-wallpaperengine.overrideAttrs (old: {
    version = "0-unstable-2026-06-09";
    src = pkgs.fetchFromGitHub {
      owner = "Almamu";
      repo = "linux-wallpaperengine";
      rev = "b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d";
      fetchSubmodules = true;
      hash = "sha256-ExWAYdSFW5plPuS3/jxTPMXIly6zVb5GojE3e37imZM=";
    };
    # #606 added a D-Bus media source; nixpkgs#531461 pairs the bump with this dep.
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.dbus ];
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/linux-wallpaperengine \
        --append-flags "--layer background"
    '';
  });
in
{
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.keyd = {
    enable = true;
    keyboards.default.settings.main = {
      end = "noop";
      leftcontrol = "leftcontrol";
      leftshift = "leftshift";
      pagedown = "noop";
      pageup = "noop";
      rightcontrol = "rightcontrol";
      rightshift = "rightshift";
    };
  };

  services.udev.extraRules = ''
    KERNEL=="event*", SUBSYSTEM=="input", ATTRS{name}=="keyd virtual keyboard", GROUP="users", MODE="0660", SYMLINK+="input/by-id/keyd-virtual-keyboard-%k"
  '';

  services.xserver.enable = true;
  services.displayManager.ly.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  # fbcon uses the smallest connected mode for its visible surface. Give both
  # outputs a common 4K boot mode so Ly can center against the full framebuffer.
  boot.kernelParams = [
    "video=DP-3:3840x2160@60"
    "video=HDMI-A-1:3840x2160@60"
    "pci=realloc"
  ];
  console = {
    font = "ter-v32n";
    packages = [ pkgs.terminus_font ];
  };

  # ── Niri (scrollable tiling Wayland compositor) ──────────
  programs.niri = {
    enable = true;
    package = niri;
  };

  # niri reads ~/.config/niri/config.kdl at startup — a symlink into this repo
  # created by nixos-activation.service (system.userActivationScripts.dotfiles).
  # impermanence wipes ~/.config every boot, so those symlinks are recreated on
  # each login. Without ordering, niri.service races the (slow) activation script
  # and on a lost race finds no config, writes a default, and loads built-in
  # defaults until the next login. Order niri after activation so the symlinks
  # always exist first.
  systemd.user.services.niri = {
    after = [ "nixos-activation.service" ];
    wants = [ "nixos-activation.service" ];
  };


  # Desktop apps
  users.users.${username}.packages = with pkgs; [
    gnome-calculator
    gnome-disk-utility
    gnome-logs
    baobab
    gparted
    mission-center
    gnome-pomodoro
    gnome-text-editor
    nautilus

    cliphist
    linux-wallpaperengine-niri # Live wallpaper (background-layer wrap; see let-block)
    nwg-look # GTK settings


    zbar # Barcode scanner
    imagemagick
    grim
    (tesseract.override {
      enableLanguages = [ "eng" "ara" ];
    })
    gifski
    jq
    slurp
    wl-screenrec

    xdg-desktop-portal
    vicinae # Launcher
  ];

  # Needed for nautilus to mount partitions 
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  programs.gpu-screen-recorder.enable = true;

  services.lact = {
    enable = true;
    package = lact;
    settings = {
      version = 6;
      daemon = {
        log_level = "info";
        admin_group = "wheel";
      };
      apply_settings_timer = 5;
      current_profile = "quiet";

      # Boot default == the `balanced` daily profile below (≈ ±2% perf / −110W vs stock).
      gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.balanced // {
        power_cap = 490.0;
        gpu_vf_curve = mkRtx5090FlatCurve 2900 rtx5090Vf950Plus;
      };

      # The perf/power figures on each profile are ESTIMATES vs `stock` (600W,
      # full boost) under 4K GPU-bound load, from community data on comparable
      # cards. They shrink in CPU-bound / lower-res scenes and vary with silicon.
      # Note stock is itself power-throttled in the heaviest titles — that's how
      # the top profiles beat it at equal-or-less power. Verify on your own chip.
      profiles = {
        # Est. vs stock: 0% perf / 0W — this IS the baseline.
        # Stock NVIDIA boost behavior, with only the 600W board cap pinned.
        stock.gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.stock // {
          power_cap = 600.0;
        };

        # Est. vs stock: ≈ +7-11% perf / ≈ 0W (same 600W) — free clocks + bandwidth.
        # Max performance / benchmarking. Flat-caps at 3100MHz from the 1000mV
        # band, full 600W. Mirrors the enthusiast "max" tier (~.975-1.0V set @
        # 3100-3165, roughly +7-11% over stock on a good chip). Memory pushed for
        # bandwidth. If a game/bench crashes, walk the curve down 25-50MHz at a
        # time; if you see sparkles/flicker first, back the memory offset down.
        overclock.gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.overclock // {
          power_cap = 600.0;
          gpu_vf_curve = mkRtx5090FlatCurve 3100 rtx5090Vf1000Plus;
          mem_clock_offsets = { "0" = 1000; }; # GDDR7 OC, P0 — validate (see notes)
        };

        # Est. vs stock: ≈ +5-7% perf / ≈ −75W (−13%) — beats stock for less power.
        # Performance undervolt: 3100MHz from 975mV upward, ~525W. Tracks the
        # widely-cited ".975 @ 3000-3130" sweet spot — clearly above stock while
        # pulling well under the 600W wall (the 525W cap clips it toward ~3000-3050
        # in the heaviest scenes). If 3100 isn't stable this low, drop the target
        # toward 3000/2950, or raise the floor to rtx5090Vf1000Plus.
        performance-undervolt.gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.performance // {
          power_cap = 525.0;
          gpu_vf_curve = mkRtx5090FlatCurve 3100 rtx5090Vf975Plus;
          mem_clock_offsets = { "0" = 1000; }; # GDDR7 OC, P0 — validate (see notes)
        };

        # Est. vs stock: ≈ ±2% perf (within 1-3 FPS) / ≈ −110W (−18%) — near-free efficiency.
        # Daily default: 2900MHz from the 950mV band. After Boost-5 droop this
        # settles near ~900mV effective — the community daily sweet spot, with
        # near-zero perf loss vs stock but markedly lower temps and power. ~490W.
        balanced.gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.balanced // {
          power_cap = 490.0;
          gpu_vf_curve = mkRtx5090FlatCurve 2900 rtx5090Vf950Plus;
        };

        # Est. vs stock: ≈ −2-4% perf / ≈ −150W (−25%) — a few FPS traded for low noise.
        # Quiet: 2850MHz from the 950mV band, ~450W. A light clock/power trim off
        # balanced for lower fan noise with minimal real-world FPS loss.
        quiet.gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.quiet // {
          power_cap = 450.0;
          gpu_vf_curve = mkRtx5090FlatCurve 2850 rtx5090Vf950Plus;
        };

        # Est. vs stock: ≈ −5-10% perf / ≈ −200W (−33%) — best perf/W of the set.
        # Eco / max efficiency: 2700MHz from the 940mV band (~890mV effective),
        # 400W. The ".9 @ 2700-2750" efficiency tier — best perf/W; may dip just
        # under stock only in the very heaviest scenes.
        eco.gpus.${rtx5090Id} = mkRtx5090FanControl rtx5090FanCurves.eco // {
          power_cap = 400.0;
          gpu_vf_curve = mkRtx5090FlatCurve 2700 rtx5090Vf940Plus;
        };
      };
    };
  };
  systemd.services.lactd.serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/lactd.sock";
  environment.etc."lact/config.yaml".source = lib.mkForce (mkLactConfig config.services.lact.settings);


  # ── Noctalia (panel/shell for niri) ──────────────────────
  environment.systemPackages = [
    inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
    pkgs.evtest
    pkgs.wl-clipboard
    pkgs.xwayland-satellite
    pkgs.adw-gtk3
  ];

  services.upower.enable = true;
  services.power-profiles-daemon.enable = lib.mkDefault true;

  hardware.nvidia = {
    open = true;
    nvidiaSettings = true;
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Reduce niri VRAM usage by disabling NVIDIA's free buffer pool reuse
  # https://github.com/niri-wm/niri/wiki/Nvidia
  environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json".text = builtins.toJSON {
    rules = [
      {
        pattern = {
          feature = "procname";
          matches = "niri";
        };
        profile = "Limit Free Buffer Pool On Wayland Compositors";
      }
    ];
    profiles = [
      {
        name = "Limit Free Buffer Pool On Wayland Compositors";
        settings = [
          {
            key = "GLVidHeapReuseRatio";
            value = 0;
          }
        ];
      }
    ];
  };

  hardware.nvidia-container-toolkit.enable = true;

  # nixpkgs.config.cudaSupport = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ mangohud nvidia-vaapi-driver ];
    extraPackages32 = with pkgs; [ pkgsi686Linux.mangohud ];
  };

  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "ghostty";
  };
}
