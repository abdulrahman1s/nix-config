{ lib, pkgs, config, inputs, username, ... }:
let
  noctaliaPackage = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.noctalia;
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

  console = {
    font = "ter-v32n";
    packages = [ pkgs.terminus_font ];
  };

  # ── Niri (scrollable tiling Wayland compositor) ──────────
  programs.niri = {
    enable = true;
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

  systemd.user.services.noctalia = {
    description = "Noctalia desktop shell";
    wantedBy = [ "niri.service" ];
    after = [ "niri.service" ];
    partOf = [ "niri.service" ];
    unitConfig.StartLimitIntervalSec = 0;
    # The generated unit's PATH overrides the user manager's PATH; Noctalia
    # needs the profile bins to launch applications from desktop entries.
    path = [
      "${config.users.users.${username}.home}/.local"
      "${config.users.users.${username}.home}/.nix-profile"
      "/nix/profile"
      "${config.users.users.${username}.home}/.local/state/nix/profile"
      "/etc/profiles/per-user/${username}"
      "/nix/var/nix/profiles/default"
      "/run/current-system/sw"
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${noctaliaPackage}/bin/noctalia";
      Restart = "on-failure";
      RestartSec = 2;
    };
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

    linux-wallpaperengine
    nwg-look # GTK settings

    imagemagick
    (tesseract.override {
      enableLanguages = [ "eng" "ara" ];
    })
    gifski
    cliphist
    zbar # Barcode scanner
    grim
    jq
    nvtopPackages.nvidia
    slurp
    wl-screenrec

    xdg-desktop-portal
    vicinae # Launcher
  ];

  # Needed for nautilus to mount partitions
  services.udisks2.enable = true;
  services.gvfs.enable = true;

  programs.gpu-screen-recorder.enable = true;

  # ── Noctalia (panel/shell for niri) ──────────────────────
  environment.systemPackages = [
    noctaliaPackage
    pkgs.evtest
    pkgs.wl-clipboard
    pkgs.xwayland-satellite
    pkgs.adw-gtk3
    pkgs.kdePackages.breeze-icons
  ];

  services.upower.enable = true;
  services.power-profiles-daemon.enable = lib.mkDefault true;

  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "ghostty";
  };
}
