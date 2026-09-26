# Independently installed NixOS environment for repairing the main impermanent
# system. It owns a separate Limine bootloader on the SN350.
{ config, inputs, lib, pkgs, username, ... }:
let
  systemChroot = pkgs.writeShellApplication {
    name = "system-chroot";
    runtimeInputs = with pkgs; [
      btrfs-progs
      coreutils
      nixos-install-tools
      util-linux
    ];
    text = ''
      export RECOVERY_USERNAME=${lib.escapeShellArg username}
      ${builtins.readFile ./system-chroot.sh}
    '';
  };
in
{
  boot = {
    loader = {
      grub.enable = false;
      efi.canTouchEfiVariables = false;
      limine = {
        enable = true;
        biosSupport = false;
        biosDevice = "nodev";
        efiSupport = true;
        efiInstallAsRemovable = true;
        maxGenerations = 3;
      };
      timeout = 3;
    };
    initrd = {
      systemd.enable = true;
      availableKernelModules = [
        "nvme"
        "xhci_pci"
        "ahci"
        "usb_storage"
        "usbhid"
        "uas"
        "sd_mod"
      ];
    };
    kernelModules = [ "kvm-amd" ];
    kernelPackages = pkgs.linuxPackages;
    supportedFilesystems = [
      "btrfs"
      "ext4"
      "vfat"
      "ntfs"
    ];
  };

  nixpkgs.config.allowUnfree = true;

  networking = {
    hostName = "nixos-recovery";
    networkmanager.enable = true;
    useDHCP = lib.mkDefault true;
  };

  users = {
    mutableUsers = false;
    users.root.hashedPasswordFile = "/etc/recovery-root-password-hash";
    users.${username} = {
      isNormalUser = true;
      hashedPasswordFile = "/etc/recovery-root-password-hash";
      extraGroups = [
        "networkmanager"
        "wheel"
      ];
    };
  };

  services = {
    displayManager = {
      defaultSession = "niri";
      ly.enable = true;
    };
    openssh.enable = false;
    udisks2.enable = true;
  };

  programs.niri.enable = true;

  # Keep the recovery desktop independent from the main system's monitor and
  # application layout while still providing the same compositor and shell.
  environment.etc."nixos-recovery/niri/config.kdl".source = ./niri.kdl;
  environment.etc."nixos-recovery/niri/binds.kdl".source = ../config/niri/binds.kdl;
  environment.etc."nixos-recovery/niri/cycle-same-app".source = ../config/niri/cycle-same-app;
  environment.etc."nixos-recovery/niri/focus-column".source = ../config/niri/focus-column;
  environment.etc."nixos-recovery/niri/game-mode".source = ../config/niri/game-mode;
  environment.etc."nixos-recovery/niri/maximize-window".source = ../config/niri/maximize-window;
  environment.etc."nixos-recovery/niri/niri-launch-or-focus".source = ../config/niri/niri-launch-or-focus;
  environment.etc."nixos-recovery/niri/niri-launch-or-focus-webapp".source = ../config/niri/niri-launch-or-focus-webapp;
  environment.etc."nixos-recovery/niri/peek-floating-window".source = ../config/niri/peek-floating-window;
  system.userActivationScripts.recovery-niri-config.text = ''
    install -d -m 0755 "$HOME/.config/niri"
    for config in /etc/nixos-recovery/niri/*; do
      ln -sfn "$config" "$HOME/.config/niri/$(basename "$config")"
    done
  '';

  hardware = {
    enableRedistributableFirmware = true;
    graphics.enable = true;
    nvidia = {
      open = true;
      modesetting.enable = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
  };

  systemd.user.services.polkit-gnome-authentication-agent = {
    description = "PolicyKit authentication agent";
    wantedBy = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      Restart = "on-failure";
    };
  };

  environment.systemPackages = with pkgs; [
    systemChroot
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.noctalia
    # A native package is intentional here because this separate repair
    # installation does not have the main system's NixPak runtime or profile paths.
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.brave-origin
    btrfs-progs
    cryptsetup
    curl
    ddrescue
    dosfstools
    e2fsprogs
    efibootmgr
    git
    gparted
    gptfdisk
    nano
    networkmanager
    networkmanagerapplet
    nixos-install-tools
    nvme-cli
    parted
    pciutils
    pcmanfm
    polkit_gnome
    ripgrep
    smartmontools
    testdisk
    usbutils
    vim
    wget
    wl-clipboard
    xterm
  ];

  nix = {
    settings.experimental-features = [ "nix-command" "flakes" ];
    gc.automatic = true;
    optimise.automatic = true;
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  security = {
    polkit.enable = true;
    sudo = {
      enable = true;
      wheelNeedsPassword = true;
    };
  };

  time.timeZone = "Africa/Cairo";
  i18n.defaultLocale = "en_US.UTF-8";

  system.stateVersion = "26.11";
}
