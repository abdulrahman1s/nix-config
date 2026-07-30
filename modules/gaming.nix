{ config, pkgs, username, ... }:
let
  aulaF75RgbMonitor = pkgs.writeText "aula-f75-rgb-monitor.py" (
    builtins.readFile ./aula-f75-rgb-monitor.py
  );
in
{

  programs.steam = {
    enable = true;
    protontricks.enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    extraCompatPackages = [
      pkgs.proton-ge-bin
    ];
  };

  # While a game runs, raises CPU governor + sched priority + I/O priority.
  # Activate per-game via Steam launch options: `gamemoderun %command%`.
  programs.gamemode.enable = true;

  # NEEDED FOR VR YASTA
  hardware.steam-hardware.enable = true;


  users.users.${username}.packages = with pkgs; [
    # legendary-gl # CLI Client for Epic Games store.
    protonup-qt
    steam-run
    gamescope
    mangohud # FPS overlay for games.
    # umu-launcher # A tweaked Steam Runtime and Steam Linux Runtime for non-Steam use.
    razergenie
    razer-cli
    mangojuice
  ];


  hardware.openrazer = {
    enable = true;
    batteryNotifier = {
      enable = true;
      percentage = 10;
    };
  };


  # Support Logitech G29 Racing Wheel
  hardware.new-lg4ff.enable = true;

  # services.udev.packages = with pkgs; [
  #   chrysalis # https://github.com/NixOS/nixpkgs/blob/fea4a1365abce59be3bbaa1a1ba5a990f116e014/pkgs/applications/misc/chrysalis/default.nix#L32
  #   (writeTextFile {
  #     name = "logitech-wheel-udev-rules";
  #     destination = "/etc/udev/rules.d/99-logitech-wheel.rules";
  #     # Logitech G29 Driving Force Racing Wheel
  #     text = ''
  #       SUBSYSTEMS=="hid", KERNELS=="0003:046D:C24F.????", DRIVERS=="logitech", SYMLINK+="logitech_g29", RUN+="${bash}/bin/sh -c 'chmod 666 %S%p/../../../range; chmod 777 %S%p/../../../leds/ %S%p/../../../leds/*; chmod 666 %S%p/../../../leds/*/brightness'"
  #     '';
  #   })
  # ];

  # Enable Mangohud for all steam games
  environment.sessionVariables.MANGOHUD = "1";

  systemd.user.services.steam-shortcut-cleanup = {
    description = "Remove Steam-generated .desktop entries";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "steam-shortcut-cleanup" ''
        ${pkgs.findutils}/bin/find \
          "$HOME/.local/share/applications" "$HOME/Desktop" \
          -maxdepth 1 -type f -name '*.desktop' \
          -exec ${pkgs.gnugrep}/bin/grep -lZ 'steam://rungameid/' {} + 2>/dev/null \
          | ${pkgs.findutils}/bin/xargs -0 -r rm -f
      '';
    };
  };

  systemd.user.paths.steam-shortcut-cleanup = {
    wantedBy = [ "default.target" ];
    pathConfig.PathChanged = [
      "%h/.local/share/applications"
      "%h/Desktop"
    ];
  };


  # RGB lighting support
  hardware.i2c.enable = true; # Enable I2C support
  

  services.hardware.openrgb = let
    openrgbAulaF75 = pkgs.openrgb.overrideAttrs (_: {
      version = "1.0rc2-unstable-2026-07-09";
      src = pkgs.fetchFromGitLab {
        owner = "CalcProgrammer1";
        repo = "OpenRGB";
        rev = "b833a43490a7c7c85fd6cd0fb09dd7d734504671";
        hash = "sha256-K1GaViybuKg+eRXcrv/Q1gdFVA1H8Tvs4y16xzfXqTk=";
      };
      patches = [
        (pkgs.path + "/pkgs/by-name/op/openrgb/system-plugins-env.patch")
      ];
    });
    openrgbEffectsApi5 = pkgs.openrgb-plugin-effects.overrideAttrs (_: {
      version = "unstable-2026-07-07";
      src = pkgs.fetchFromGitLab {
        owner = "OpenRGBDevelopers";
        repo = "OpenRGBEffectsPlugin";
        rev = "f9dc7312aa2097360144c4b7d6971bb2cf13d0f6";
        hash = "sha256-udObEA7081UZSZJLwyKsHPthmTu5cAGDcaEOE0hqLpE=";
        fetchSubmodules = true;
      };
    });
    openrgbHardwareSyncApi5 = pkgs.openrgb-plugin-hardwaresync.overrideAttrs (_: {
      version = "unstable-2026-07-07";
      src = pkgs.fetchFromGitLab {
        owner = "OpenRGBDevelopers";
        repo = "OpenRGBHardwareSyncPlugin";
        rev = "46189c4656f38af4c6d3a51c6fefa42dd4fa367d";
        hash = "sha256-oqFHGVNAhSL+Gli9DfaqI0IAFalCtImAuM7Aaq8NVnU=";
        fetchSubmodules = true;
      };
    });
    openrgbVisualMapApi5 = pkgs.stdenv.mkDerivation {
      pname = "openrgb-plugin-visualmap";
      version = "unstable-2026-07-07";
      src = pkgs.fetchFromGitLab {
        owner = "OpenRGBDevelopers";
        repo = "OpenRGBVisualMapPlugin";
        rev = "84accb0b833d4d9c7a51311cf848113b0d0de3c4";
        hash = "sha256-P6TskKsNwGQxoA1AKME24P1qMiRgW+zGP8xHVV1J2vQ=";
        fetchSubmodules = true;
      };
      nativeBuildInputs = with pkgs; [
        pkg-config
        qt6Packages.qmake
        qt6Packages.wrapQtAppsHook
      ];
      buildInputs = [
        pkgs.qt6Packages.qtbase
      ];
    };
  in {
    enable = true;
    motherboard = "amd";
    package = openrgbAulaF75.withPlugins [
      openrgbEffectsApi5
      openrgbHardwareSyncApi5
      openrgbVisualMapApi5
    ];
  };

  systemd.services.openrgb.restartTriggers = [ aulaF75RgbMonitor ];

  systemd.services.aula-f75-rgb-monitor = {
    description = "AULA F75 RGB system monitor";
    after = [
      "keyd.service"
      "openrgb.service"
    ];
    partOf = [ "openrgb.service" ];
    requires = [ "openrgb.service" ];
    wants = [ "keyd.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      config.programs.niri.package
      pkgs.wireplumber
    ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${aulaF75RgbMonitor}";
      Restart = "always";
      RestartSec = "3";
      User = username;
      Group = "users";
      SupplementaryGroups = [
        "input"
        "users"
      ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = "read-only";
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };

  services.udev.extraRules = ''
    SUBSYSTEMS=="usb|hidraw", ATTRS{idVendor}=="258a", ATTRS{idProduct}=="010c", TAG+="uaccess", TAG+="AULA_F75", GROUP="users", MODE="0660"
    KERNEL=="event*", SUBSYSTEM=="input", ATTRS{idVendor}=="258a", ATTRS{idProduct}=="010c", TAG+="uaccess", TAG+="AULA_F75", GROUP="users", MODE="0660"
  '';

  boot.blacklistedKernelModules = [
    # This module causes OpenRGB to not detect RAM.
    "ee1004"
  ];
}
