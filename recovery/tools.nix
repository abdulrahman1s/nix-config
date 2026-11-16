# The repair commands (system-chroot, main-logs, disk-health, resize-990pro)
# and the command-line toolbox for disks, data rescue, hardware and network.
{ inputs, lib, pkgs, username, ... }:
let
  mainConfig = inputs.self.nixosConfigurations.default.config;
  mainPersistence = mainConfig.environment.persistence."/persist";
  mainBtrfsDevice = mainConfig.fileSystems."/".device;

  # x-* options only guide systemd and the initrd; plain mount does not need them.
  mountOptions = options:
    lib.concatStringsSep "," (lib.filter (option: !lib.hasPrefix "x-" option) options);
  byDepth = attribute: lib.sort (a: b: lib.stringLength a.${attribute} < lib.stringLength b.${attribute});

  # Read from the main configuration so the repair tools follow
  # hardware-configuration.nix and system/impermanence.nix instead of copies.
  mainMounts = pkgs.writeText "system-chroot-mounts" (lib.concatStrings (
    map (fs: "btrfs\t${fs.device}\t${fs.mountPoint}\t${mountOptions fs.options}\n")
      (byDepth "mountPoint" (lib.filter (fs: fs.fsType == "btrfs" && fs.device == mainBtrfsDevice)
        (lib.attrValues mainConfig.fileSystems)))
    ++ [ "vfat\t${mainConfig.fileSystems."/boot".device}\t/boot\t${mountOptions mainConfig.fileSystems."/boot".options}\n" ]
    ++ map (dir: "dir\t${dir.persistentStoragePath}${dir.dirPath}\t${dir.dirPath}\n")
      (byDepth "dirPath" (mainPersistence.directories
        ++ lib.concatMap (user: user.directories) (lib.attrValues mainPersistence.users)))
    ++ map (file: "file\t${file.persistentStoragePath}${file.filePath}\t${file.filePath}\n")
      (byDepth "filePath" (mainPersistence.files
        ++ lib.concatMap (user: user.files) (lib.attrValues mainPersistence.users)))
  ));

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
      export SYSTEM_CHROOT_MOUNTS=${mainMounts}
      # The main initrd deletes these and re-snapshots them from <name>-blank on
      # every boot; see system/impermanence.nix.
      export SYSTEM_CHROOT_ROLLBACK_SUBVOLUMES="root home"
      ${builtins.readFile ./scripts/system-chroot.sh}
    '';
  };

  mainLogs = pkgs.writeShellApplication {
    name = "main-logs";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      # journalctl's pager.
      less
      systemd
      util-linux
    ];
    text = ''
      export SYSTEM_CHROOT_MOUNTS=${mainMounts}
      ${builtins.readFile ./scripts/main-logs.sh}
    '';
  };

  diskHealth = pkgs.writeShellApplication {
    name = "disk-health";
    runtimeInputs = with pkgs; [
      coreutils
      smartmontools
      util-linux
    ];
    text = builtins.readFile ./scripts/disk-health.sh;
  };

  # Grows the main Btrfs partition into the start of the 990 PRO ext4 data
  # partition. The identity values must all match before anything is changed.
  resize990Pro = pkgs.writeShellApplication {
    name = "resize-990pro";
    runtimeInputs = with pkgs; [
      btrfs-progs
      coreutils
      diffutils
      e2fsprogs
      gawk
      gnugrep
      gnused
      smartmontools
      systemd
      util-linux
    ];
    text = ''
      export RESIZE_DISK_LINK=/dev/disk/by-id/nvme-eui.0025384141406d90
      export RESIZE_DISK_MODEL=${lib.escapeShellArg "Samsung SSD 990 PRO 2TB"}
      export RESIZE_DISK_SERIAL=S7DNNJ0X108801L
      export RESIZE_BTRFS_UUID=ddb4bdb8-c522-4420-ba2d-ace00fc2054b
      export RESIZE_EXT4_UUID=14e3b93d-5c7e-449c-b348-6e79e8228a08
      export RESIZE_TARGET_GIB=500
      ${builtins.readFile ./scripts/resize-990pro.sh}
    '';
  };
in
{
  environment.systemPackages = with pkgs; [
    systemChroot
    mainLogs
    diskHealth
    resize990Pro
    btrfs-progs
    cryptsetup
    curl
    ddrescue
    dosfstools
    e2fsprogs
    efibootmgr
    # Enough for flakes and inspecting the repository, without Perl and Python.
    gitMinimal
    gptfdisk
    jq
    nano
    networkmanager
    nixos-install-tools
    nvme-cli
    parted
    pciutils
    ripgrep
    smartmontools
    testdisk
    usbutils
    vim
    wget
    wl-clipboard

    # Disks and data: what filled a disk, real Btrfs usage, exFAT USB drives,
    # SATA drive settings, and copy progress. GNOME Disks was left out: it
    # brings gnome-settings-daemon and about 100 MiB with it.
    ncdu
    compsize
    exfatprogs
    hdparm
    pv
    # Archives: 7-Zip opens nearly every format.
    _7zz
    unzip
    # Hardware: temperatures, firmware tables, a full hardware list, and a live
    # monitor for CPU, memory, disks and processes (2 MiB, where Mission
    # Center is 60 MiB).
    lm_sensors
    dmidecode
    lshw
    btop
    # Processes and files: what holds a mount busy (fuser, lsof), sessions that
    # survive a closed window, quick file identification.
    psmisc
    lsof
    tmux
    file
    tree
    # Network: DNS lookups, route and packet-loss tracing, link and Wi-Fi state.
    dnsutils
    mtr
    ethtool
    iw
  ];
}
