# Independently installed NixOS environment for repairing the main impermanent
# system. It owns a separate Limine bootloader on the SN350.
{ config, lib, pkgs, username, ... }:
{
  imports = [
    ./tools.nix
    ./desktop.nix
    ./shell.nix
    ./vm.nix
  ];

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
        # A RAM test that runs without any operating system, for random
        # crashes or corruption that might be bad memory.
        additionalFiles."efi/memtest86/memtest.efi" = pkgs.memtest86plus.efi;
        extraEntries = ''
          /Memtest86+ (RAM test)
            protocol: efi
            path: boot():/efi/memtest86/memtest.efi
        '';
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
    # Same as the main system (system/graphics.nix): fbcon uses the smallest
    # connected mode, so both outputs get a common 4K boot mode and Ly centers
    # against the full framebuffer.
    kernelParams = [
      "video=DP-3:3840x2160@60"
      "video=HDMI-A-1:3840x2160@60"
    ];
    # The LTS kernel deliberately differs from the main system's CachyOS kernel,
    # so a regression in one does not take both installations down.
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
      defaultSession = "labwc";
      ly.enable = true;
    };
    openssh.enable = false;
    # Nothing here uses speech synthesis; its voices alone are about 700 MiB.
    speechd.enable = false;
    udisks2.enable = true;
    # The hardware.nvidia options below only take effect when this lists nvidia.
    xserver.videoDrivers = [ "nvidia" ];
  };

  hardware = {
    enableRedistributableFirmware = true;
    graphics.enable = true;
    nvidia = {
      # The RTX 5090 (Blackwell) is only supported by the open kernel modules.
      open = true;
      modesetting.enable = true;
      nvidiaSettings = false;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
  };

  # A second boot entry without the NVIDIA driver, for when it fails to load or
  # shows a black screen: nouveau if it can drive the card, otherwise the
  # firmware framebuffer with software rendering.
  specialisation.safe-graphics.configuration = {
    system.nixos.tags = [ "safe-graphics" ];
    services.xserver.videoDrivers = lib.mkForce [
      "modesetting"
      "fbdev"
    ];
  };

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

  # Ly fixes shared with the main system (modules/desktop.nix and
  # configuration.nix): Ly draws with the console font, which needs to be large
  # on 4K, and it owns tty1, so no getty may compete for that console.
  console = {
    font = "ter-v32n";
    packages = [ pkgs.terminus_font ];
  };
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  time.timeZone = "Africa/Cairo";
  i18n.defaultLocale = "en_US.UTF-8";

  system.stateVersion = "26.11";
}
