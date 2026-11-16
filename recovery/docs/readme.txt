NIXOS RECOVERY - SHELL TOOLS CHEAT SHEET
========================================

Open a terminal from the dock (Ghostty, or Foot if Ghostty fails).
Commands marked [root] need sudo; the password is the main system's root
password. The full guide is "Recovery Guide" in the dock.


1. MAIN SYSTEM DOESN'T BOOT - TRY IN THIS ORDER
-----------------------------------------------
  - Main boot menu: pick an older generation. Often enough on its own.
  - [root] sudo main-logs
        Warnings and errors from the last main boot, read-only.
  - [root] sudo system-chroot
        Shell inside the main system. Exit it to unmount everything.
        Inside:  nixos-rebuild boot --flake /home/abdulrahman/system-conf#default
                 nixos-rebuild boot --rollback      (previous generation)
                 journalctl --list-boots
                 journalctl -b -1 -p err            (errors, boot before last)
  - [root] sudo system-chroot --reinstall-bootloader
        Firmware forgot the main disk, or the Limine menu is broken.
  - [root] sudo fsck.vfat -a /dev/disk/by-uuid/FE76-C46F
        Main EFI partition is damaged. Run before the bootloader repair.
  - Recovery boot menu: "Memtest86+ (RAM test)" for random crashes.
  - Recovery boot menu: "safe-graphics" if this desktop shows a black screen.


2. DISK MAP (device numbers like nvme0n1 can change; use these)
--------------------------------------------------------------
  Samsung 990 Pro (main system)
    EFI     /dev/disk/by-uuid/FE76-C46F
    Btrfs   /dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b
            subvolumes: root home nix persist (+ root-blank home-blank)
    ext4    /dev/disk/by-uuid/14e3b93d-5c7e-449c-b348-6e79e8228a08  (/mnt/990Pro)
  WD Green SN350 (this recovery)
    labels RECOVERYEFI, NIXOS-RECOVERY, SN350 (data, mounted at /mnt/SN350)
  Recovery USB drive (the same system, if you boot from it)
    labels RECOVUSBEFI, RECOVERY-USB
  WD Black SN770   /dev/disk/by-uuid/aa282c6c-483b-4da5-a1ca-2149359cbe7d
  Kingston NV3     /dev/disk/by-uuid/e0948a1b-026f-420f-8450-19a9b7963e23

  Browse the main system's files read-only, without the chroot:
    sudo mkdir -p /mnt/main
    sudo mount -o ro,subvol=persist /dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b /mnt/main
    ...
    sudo umount /mnt/main


3. DISKS AND FILESYSTEMS
------------------------
  lsblk -f                      every disk, partition, filesystem and label
  findmnt                       what is mounted where
  sudo blkid                    UUIDs and filesystem types
  udisksctl mount -b /dev/X     mount a USB drive as your user (or use Files)
  gparted                       partition editor (GUI, in the dock)
  sudo parted /dev/X print      partition table; gdisk / sgdisk for GPT work
  sudo disk-health              SMART health of every drive
  sudo smartctl -a /dev/nvme0n1 full SMART report for one drive
  sudo nvme smart-log /dev/nvme0n1   NVMe wear, temperature, media errors
  sudo hdparm -I /dev/sda       SATA drive details

  Btrfs (main system)
    sudo btrfs check --readonly /dev/disk/by-uuid/ddb4...   check, unmounted
        Never run "btrfs check --repair" without a backup; ask first.
    sudo btrfs scrub start -B -r /mnt/main  verify every checksum; -r only
                                            reports (needed on a read-only mount)
    sudo btrfs device stats /mnt/main      read/write/corruption error counts
    sudo btrfs filesystem usage /mnt/main  real free space
    sudo compsize /mnt/main                size on disk after compression
  ext4:   sudo e2fsck -f /dev/X     (unmounted)    sudo tune2fs -l /dev/X
  FAT:    sudo fsck.vfat -a /dev/X
  exFAT:  sudo fsck.exfat /dev/X    sudo mkfs.exfat -L NAME /dev/X
  NTFS:   sudo ntfsfix /dev/X
  LUKS:   sudo cryptsetup open /dev/X name   then mount /dev/mapper/name


4. RESCUE AND COPY DATA
-----------------------
  ddrescue    copy a failing disk; rerun the same command to resume
                sudo ddrescue -d /dev/X /mnt/SN350/disk.img /mnt/SN350/disk.map
  testdisk    find lost partitions and repair partition tables
  photorec    recover deleted files by content (comes with testdisk)
  rsync       copy folders with progress, resumable
                rsync -aHAX --info=progress2 /source/ /destination/
  pv          progress bar for pipes:  pv big.img > /dev/null
  ncdu -x /   find what filled a disk (stays on one filesystem)
  7zz x file  extract nearly any archive (zip, 7z, rar, iso, ...)
  unzip, tar, zstd, xz, gzip     the usual archive tools


5. HARDWARE
-----------
  btop                 live CPU, memory, disks, network, processes (also
                       "System Monitor" in the dock)
  sensors              temperatures and fan speeds
  nvidia-smi           GPU state (default boot entry only, not safe-graphics)
  sudo dmidecode -t memory   installed RAM modules and speeds
  sudo lshw -short     every hardware component
  lspci -k             PCI devices and the driver each one uses
  lsusb                USB devices
  sudo dmesg -w        kernel messages, live (journalctl -k -b for this boot)


6. PROCESSES AND FILES
----------------------
  fuser -vm /mnt/X      who keeps a mount busy ("target is busy")
  lsof +f -- /mnt/X     open files on a mount
  killall NAME          stop processes by name
  tmux                  sessions that survive a closed window:
                          tmux new -s work, then Ctrl+B D to detach,
                          tmux attach -t work to come back
  rg TEXT /path         fast text search;  file X  tells what a file is
  tree -L 2 /path       directory overview
  jq                    read JSON
  wl-copy / wl-paste    clipboard:  journalctl -b -p err | wl-copy
  nano FILE             simple editor (Ctrl+O save, Ctrl+X quit); vim too


7. NETWORK
----------
  Wired Ethernet connects by itself. For Wi-Fi use the bar's network button
  or:
  nmtui                                       text menu for connections
  nmcli device wifi connect "SSID" --ask      join Wi-Fi
  ip -br address                              interfaces and addresses
  ping -c3 1.1.1.1     then   ping -c3 nixos.org      (IP vs DNS problem)
  dig nixos.org        DNS lookup;   mtr 1.1.1.1   route and packet loss
  ethtool enp6s0       link speed and cable state (name from ip -br link)
  iw dev               Wi-Fi state
  curl -I URL, wget URL                       test or download
  ssh, scp, sftp                              reach or copy to another machine


8. NIX
------
  nix shell nixpkgs#htop       any missing tool, temporarily (needs network)
  nixos-rebuild ...            run it inside "sudo system-chroot" for the
                               main system, not here
  Don't run garbage collection (nix-collect-garbage, nix store gc) inside
  the chroot unless you mean to delete old main-system generations.


9. AI HELP
----------
  claude / claudex      Claude Code (claudex skips permission prompts)
  codex / codexx        Codex (codexx runs without sandbox or approvals)
  Both are signed in with the main system's logins from the last
  recovery-update. If one asks to sign in: /login in Claude Code, or
  codex login.
  Give them context:  journalctl -b -1 -p err | wl-copy   then paste.


10. BOOT AND FIRMWARE
--------------------
  efibootmgr -v                    firmware boot entries
  systemctl reboot --firmware-setup   reboot into the UEFI setup
                                   (also in the session menu and right-click menu)
  One-time boot menu: choose "WD Green SN350" (or the recovery USB drive)
  to start this recovery even when the main disk's EFI partition is gone.
