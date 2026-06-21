# Hardware configuration & boot settings.
{ config, lib, modulesPath, pkgs, ... }:

{
  imports =
    [
      (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-x86_64-v3;
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" "usbhid" "uas" "sd_mod" ];
  boot.kernelModules = [ "kvm-amd" ];

  boot.supportedFilesystems = [ "fuse" ];
  programs.fuse.userAllowOther = true; # Required for the 'allow-other' flag

  # Steam's Proton needs unprivileged user namespaces for sandboxing.
  boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;

  boot.loader.limine = {
    enable = true;
    biosDevice = "nodev";
    efiSupport = true;
    resolution = "3840x2160";
    style = {
      graphicalTerminal = {
        brightPalette = "1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4";
        palette = "1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4";
        foreground = "cdd6f4";
        brightForeground = "cdd6f4";
        background = "ffffffff";
        brightBackground = "ffffffff";
      };
      interface.branding = "";
    };
    extraConfig = ''
      timeout: 3
    '';

    extraEntries = ''
      /Windows
          protocol: efi_boot_entry
          entry: Windows Boot Manager
    '';
  };

  boot.initrd.systemd.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.usb-modeswitch.enable = true;

  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b";
      fsType = "btrfs";
      options = [ "subvol=root" "compress=zstd:1" "noatime" ];
    };

  fileSystems."/home" =
    {
      device = "/dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b";
      fsType = "btrfs";
      options = [ "subvol=home" "compress=zstd:1" "noatime" ];
    };

  fileSystems."/nix" =
    {
      device = "/dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b";
      fsType = "btrfs";
      options = [ "subvol=nix" "compress=zstd:1" "noatime" ];
    };

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/FE76-C46F";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  fileSystems."/mnt/SN770" = {
    device = "/dev/disk/by-uuid/aa282c6c-483b-4da5-a1ca-2149359cbe7d";
    options = [ "defaults" "noatime" "nofail" "x-gvfs-show" "x-gvfs-name=SN770" "x-systemd.device-timeout=5s" ];
    fsType = "ext4";
  };

  fileSystems."/mnt/990Pro" = {
    device = "/dev/disk/by-uuid/14e3b93d-5c7e-449c-b348-6e79e8228a08";
    options = [ "defaults" "noatime" "nofail" "x-gvfs-show" "x-gvfs-name=990%20Pro" "x-systemd.device-timeout=5s" ];
    fsType = "ext4";
  };

  fileSystems."/mnt/NV3" = {
    device = "/dev/disk/by-uuid/e0948a1b-026f-420f-8450-19a9b7963e23";
    options = [ "defaults" "noatime" "nofail" "x-gvfs-show" "x-gvfs-name=NV3" "x-systemd.device-timeout=5s" ];
    fsType = "ext4";
  };

  fileSystems."/mnt/SN350" = {
    device = "/dev/disk/by-uuid/104efbfc-be71-4c9a-8d96-e21867fa0b82";
    options = [ "defaults" "noatime" "nofail" "x-gvfs-show" "x-gvfs-name=SN350" "x-systemd.device-timeout=5s" ];
    fsType = "ext4";
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
