# The SN350 recovery disk owns its bootloader and remains independently
# bootable. The main Limine menu only chainloads that separate EFI loader.
{ lib, ... }:
{
  fileSystems."/mnt/SN350".device = lib.mkForce "/dev/disk/by-label/SN350";

  boot.loader.limine.extraEntries = lib.mkAfter ''
    /NixOS Recovery
      protocol: efi
      path: fslabel(RECOVERYEFI):/EFI/BOOT/BOOTX64.EFI
  '';
}
