# RTX 5090 graphics and LACT configuration.
# TUNING
#   activeProfile is the single persistent profile selector below.
#   balanced starts at 490 W, a 2700 MHz ceiling, and +100 MHz P0 offset.
#   These are starting values, not a stability or performance guarantee.
#   A positive core offset shifts frequency upward at a given voltage. Combined
#   with a clock ceiling, this can reach that ceiling at a lower voltage.
#   It does NOT command an exact voltage or guarantee a fixed voltage reduction.
#   Power caps are limits, not expected consumption or promised watts saved.
#
# WHY THIS REPLACES THE OLD FLAT CURVE
#   LACT 0.10.1 changed NVIDIA VF storage from absolute clocks to offsets.
#   The old voltage/index table and five stock anchors cannot reconstruct every
#   offset accurately. Clock limits + P0 offsets avoid guessing those values.
#   No direct VF edits, memory OC, voltage boost, or locked-high idle clock.
#   P0 is targeted for gaming; a P2 compute workload needs separate validation.
#
# RECOVERY / PERSISTENCE
#   Set activeProfile = "stock" and rebuild to restore firmware-controlled
#   clocks, board-default power and automatic fans through LACT.
#   If the desktop hangs, reboot into a previous known-good NixOS generation.
#   Do not run another GPU tuning service alongside LACT.
#   /etc/lact/config.yaml is declarative/read-only: edit this module to persist
#   changes. GUI edits/profile selections may fail to save. The 15-second apply
#   timer covers interactive changes; it does not roll back boot-time tuning.
#
# References:
#   https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md
#   https://github.com/ilya-zlobintsev/LACT/releases/tag/v0.10.1
#   https://github.com/ilya-zlobintsev/LACT/issues/486
#   https://docs.nvidia.com/deploy/nvidia-smi/index.html
#
{ lib, pkgs, config, ... }:
let
  rtx5090Id = "10DE:2B85-196E:1431-0000:0a:00.0";
  activeProfile = "performance-undervolt";

  # Firmware fan control is the default. Opt in only after checking GPU and
  # memory temperatures under sustained load; an edge-only curve cannot respond
  # directly to a hot memory sensor. Firmware controls idle fan-stop behavior.
  useCustomFanCurves = false;
  minCoreClockMHz = 300;

  lactVersion = lib.getVersion config.services.lact.package;

  fanCurves = {
    performance = { "40" = 0.35; "50" = 0.42; "60" = 0.58; "70" = 0.80; "78" = 1.00; };
    balanced = { "40" = 0.30; "50" = 0.35; "60" = 0.50; "70" = 0.72; "80" = 1.00; };
    quiet = { "40" = 0.30; "50" = 0.32; "60" = 0.44; "70" = 0.65; "80" = 1.00; };
    eco = { "40" = 0.30; "50" = 0.32; "60" = 0.42; "70" = 0.62; "80" = 1.00; };
  };

  # All profiles leave VRAM at its factory configuration. The performance
  # profile is a more demanding candidate, not a validated speedup over stock.
  tuningProfiles = {
    performance-undervolt = {
      powerWatts = 525;
      maxCoreMHz = 2820;
      coreOffsetMHz = 125;
      fan = "performance";
    };
    balanced = {
      powerWatts = 490;
      maxCoreMHz = 2700;
      coreOffsetMHz = 100;
      fan = "balanced";
    };
    quiet = {
      powerWatts = 450;
      maxCoreMHz = 2625;
      coreOffsetMHz = 100;
      fan = "quiet";
    };
    eco = {
      powerWatts = 400;
      maxCoreMHz = 2475;
      coreOffsetMHz = 75;
      fan = "eco";
    };
  };

  mkFanControl = curve:
    { fan_control_enabled = useCustomFanCurves; }
    // lib.optionalAttrs useCustomFanCurves {
      fan_control_settings = {
        mode = "curve";
        static_speed = 0.5;
        temperature_key = "edge";
        interval_ms = 1000;
        inherit curve;
        spindown_delay_ms = 5000;
        change_threshold = 2;
        # Return control to firmware below 45 C; this does not force zero RPM.
        auto_threshold = 45;
      };
    };

  mkGpuProfile = profile:
    mkFanControl fanCurves.${profile.fan} // {
      power_cap = profile.powerWatts * 1.0;
      # NVIDIA requires both ends of the clock range. Keep a low minimum so
      # the GPU can downclock; do not set min_core_clock = max_core_clock.
      min_core_clock = minCoreClockMHz;
      max_core_clock = profile.maxCoreMHz;
      gpu_clock_offsets = { "0" = profile.coreOffsetMHz; };
    };

  gpuProfiles = builtins.mapAttrs (_: profile: mkGpuProfile profile) tuningProfiles // {
    # Omitting power_cap lets LACT restore THIS board's default. 600 W is not
    # a universal stock limit; the RTX 5090 reference specification is 575 W.
    stock = { fan_control_enabled = false; };
    # A control profile to measure the power cap without any clock tuning.
    power-limit-only = {
      fan_control_enabled = false;
      power_cap = tuningProfiles.balanced.powerWatts * 1.0;
    };
  };
  selectedGpuProfile = gpuProfiles.${activeProfile} or
    (throw "Unknown RTX 5090 activeProfile: ${activeProfile}");

  # LACT uses integer keys for fan temperatures and clock/P-state maps.
  # Convert those maps structurally: a global sed replacement could also alter
  # a numeric profile name. GPU IDs and profile names must remain strings.
  mkLactConfig = settings:
    pkgs.runCommand "lact-config.yaml" {
      nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
      settingsJSON = builtins.toJSON settings;
      passAsFile = [ "settingsJSON" ];
    } ''
      python - "$settingsJSONPath" "$out" <<'LACT_PYTHON'
      import json
      import sys
      import yaml

      with open(sys.argv[1], encoding="utf-8") as source:
          settings = json.load(source)

      def integer_keys(mapping):
          converted = {}
          for key, value in mapping.items():
              if not isinstance(key, str) or not key.isascii() or not key.isdecimal():
                  raise ValueError(f"Expected a non-negative integer map key, got {key!r}")
              integer = int(key)
              if integer in converted:
                  raise ValueError(f"Duplicate numeric map key: {key!r}")
              converted[integer] = value
          return dict(sorted(converted.items()))

      gpu_maps = [settings.get("gpus", {})]
      gpu_maps.extend(profile.get("gpus", {}) for profile in settings.get("profiles", {}).values())
      for gpu_map in gpu_maps:
          for gpu in gpu_map.values():
              for field in ("gpu_clock_offsets", "mem_clock_offsets", "gpu_vf_curve",
                            "nvidia_gpu_vf_curve", "mem_vf_curve"):
                  if field in gpu:
                      gpu[field] = integer_keys(gpu[field])
              fan = gpu.get("fan_control_settings")
              if fan is not None and "curve" in fan:
                  fan["curve"] = integer_keys(fan["curve"])

      with open(sys.argv[2], "w", encoding="utf-8") as target:
          yaml.safe_dump(settings, target, sort_keys=False)
      LACT_PYTHON
    '';
  lactConfig = mkLactConfig config.services.lact.settings;

in
{
  assertions = [
    {
      assertion = lib.versionAtLeast lactVersion "0.9.1";
      message = "This RTX 5090 module requires LACT 0.9.1 or newer.";
    }
    {
      assertion = builtins.hasAttr activeProfile gpuProfiles;
      message = "RTX 5090 activeProfile must name a profile defined in gpuProfiles.";
    }
  ] ++ lib.mapAttrsToList (name: profile: {
    assertion = minCoreClockMHz > 0
      && minCoreClockMHz <= profile.maxCoreMHz
      && profile.coreOffsetMHz >= 0
      && profile.powerWatts > 0
      && builtins.hasAttr profile.fan fanCurves;
    message = "Invalid RTX 5090 tuning values in profile ${name}.";
  }) tuningProfiles;

  services.xserver.videoDrivers = [ "nvidia" ];

  # fbcon uses the smallest connected mode for its visible surface. Give both
  # outputs a common 4K boot mode so Ly can center against the full framebuffer.
  boot.kernelParams = [
    "video=DP-3:3840x2160@60"
    "video=HDMI-A-1:3840x2160@60"
    "pci=realloc"
  ];

  # Firmware settings are not exposed uniformly. Discover display controllers
  # with PCIe Resizable BAR support and report their observable BAR mappings.
  # A mapping smaller than the largest supported size is not proof that ReBAR
  # is disabled; this check cannot infer the motherboard firmware settings.
  system.activationScripts.gpu-resizable-bar-check.text = ''
    warningPrinted=false

    printWarningHeader() {
      if [ "$warningPrinted" = false ]; then
        echo >&2
        echo "======================================================================" >&2
        echo "NOTICE: GPU BAR mappings merit a manual check." >&2
        warningPrinted=true
      fi
    }

    for pciDevice in /sys/bus/pci/devices/*; do
      [ -r "$pciDevice/class" ] || continue
      read -r pciClass < "$pciDevice/class"

      case "$pciClass" in
        0x03*) ;;
        *) continue ;;
      esac

      [ -r "$pciDevice/resource" ] || continue
      read -r vendor < "$pciDevice/vendor"
      read -r device < "$pciDevice/device"
      pciAddress="''${pciDevice##*/}"

      for resizeFile in "$pciDevice"/resource*_resize; do
        [ -r "$resizeFile" ] || continue

        resizeName="''${resizeFile##*/}"
        barNumber="''${resizeName#resource}"
        barNumber="''${barNumber%_resize}"
        read -r supportedSizesHex < "$resizeFile"
        supportedSizesHex="''${supportedSizesHex#0x}"
        [[ "$supportedSizesHex" =~ ^[[:xdigit:]]+$ ]] || continue
        supportedSizes=$((16#$supportedSizesHex))

        highestBit=-1
        for ((bit = 0; bit < 43; bit++)); do
          if ((supportedSizes & (1 << bit))); then
            highestBit=$bit
          fi
        done
        ((highestBit >= 0)) || continue

        resourceLine=$(${pkgs.gnused}/bin/sed -n "$((barNumber + 1))p" "$pciDevice/resource")
        read -r barStart barEnd barFlags <<< "$resourceLine"
        # An unassigned resource (0..0) is not an active mapping.
        ((barStart != 0 && barEnd >= barStart)) || continue
        currentSize=$((barEnd - barStart + 1))
        maximumSize=$((1 << (highestBit + 20)))
        currentSizeMiB=$((currentSize / 1024 / 1024))
        maximumSizeMiB=$((maximumSize / 1024 / 1024))

        if ((currentSize < maximumSize)); then
          printWarningHeader
          printf -- '- %s (%s:%s) BAR%s is %s MiB; the GPU supports %s MiB.\n' \
            "$pciAddress" "$vendor" "$device" "$barNumber" \
            "$currentSizeMiB" "$maximumSizeMiB" >&2
          echo "  This mapping is smaller than the hardware maximum; that can be valid." >&2
        fi

        if ((maximumSize >= 0x100000000 && barStart <= 0xffffffff)); then
          printWarningHeader
          printf -- '- %s (%s:%s) BAR%s starts below 4 GiB at %s.\n' \
            "$pciAddress" "$vendor" "$device" "$barNumber" "$barStart" >&2
          echo "  Inspect the assigned PCI resources and firmware configuration if unexpected." >&2
        fi
      done
    done

    if [ "$warningPrinted" = true ]; then
      echo "Compare with nvidia-smi -q and the Above 4G Decoding / ReBAR firmware settings." >&2
      echo "This report alone does not establish a firmware fault or a crash cause." >&2
      echo "======================================================================" >&2
    fi
  '';

  services.lact = {
    enable = true;
    package = pkgs.lact;
    settings = {
      # These schema versions correspond to LACT 0.9.1/0.10.0 and 0.10.1.
      # Recheck upstream config migration when moving to a later release series.
      version = if lib.versionAtLeast lactVersion "0.10.1" then 7 else 6;
      daemon = {
        log_level = "info";
        admin_group = "wheel";
        disable_clocks_cleanup = false;
      };
      apply_settings_timer = 15;
      auto_switch_profiles = false;
      current_profile = activeProfile;
      # The default and named selection always refer to the same settings.
      gpus.${rtx5090Id} = selectedGpuProfile;
      profiles = builtins.mapAttrs (_: gpu: {
        gpus.${rtx5090Id} = gpu;
      }) gpuProfiles;
    };
  };

  environment.etc."lact/config.yaml".source = lib.mkForce lactConfig;
  systemd.services.lactd = {
    after = [ "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
    # Also track the final file, including changes to the YAML serializer.
    restartTriggers = [ lactConfig ];
    serviceConfig = {
      RestartSec = 5;
      # Preserve the existing stale-socket workaround without replacing other
      # pre-start commands supplied by the package or another NixOS module.
      ExecStartPre = lib.mkBefore [ "${pkgs.coreutils}/bin/rm -f /run/lactd.sock" ];
    };
  };

  hardware.nvidia = {
    open = true;
    modesetting.enable = lib.mkDefault true;
    nvidiaSettings = true;
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  hardware.nvidia-container-toolkit.enable = true;

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

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ mangohud nvidia-vaapi-driver ];
    extraPackages32 = with pkgs; [ pkgsi686Linux.mangohud ];
  };
}
