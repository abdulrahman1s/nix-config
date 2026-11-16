# The same recovery system on a USB drive, written by `nix run .#recovery-usb`
# (apps/recovery-usb.sh). It boots from any UEFI firmware's boot menu, for when
# the SN350 itself fails. Used instead of disko.nix.
{
  fileSystems = {
    # Labels that differ from the SN350's (NIXOS-RECOVERY, RECOVERYEFI), so
    # both can be attached at once. FAT labels hold at most 11 characters.
    "/" = {
      label = "RECOVERY-USB";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    "/boot" = {
      label = "RECOVUSBEFI";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    # Space for rescued data when the SN350 is attached; without it, boot only
    # waits a few seconds for it.
    "/mnt/SN350" = {
      label = "SN350";
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
        "x-systemd.device-timeout=5s"
      ];
    };
  };

  # Shown in the boot menu entries.
  system.nixos.tags = [ "usb" ];
}
