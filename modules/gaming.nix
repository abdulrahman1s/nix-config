{ pkgs, username, ... }: {

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

  services.hardware.openrgb = {
    enable = true;
    motherboard = "amd";
    package = pkgs.openrgb-with-all-plugins;
  };

  boot.blacklistedKernelModules = [
    # This module causes OpenRGB to not detect RAM.
    "ee1004"
  ];
}
