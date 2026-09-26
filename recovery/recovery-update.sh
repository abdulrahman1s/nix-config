set -Eeuo pipefail

recovery_device="/dev/disk/by-partlabel/nixos-recovery"
recovery_efi_device="/dev/disk/by-partlabel/nixos-recovery-efi"
data_device="/dev/disk/by-partlabel/sn350-data"
disko_mount_root="/mnt/recovery-install"
password_hash="/run/agenix/root-password-hash"
mount_root=""

die() {
  echo "recovery-update: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n $mount_root ]]; then
    if mountpoint --quiet "$mount_root/boot"; then
      umount "$mount_root/boot" || echo "recovery-update: failed to unmount $mount_root/boot" >&2
    fi
    if mountpoint --quiet "$mount_root"; then
      umount "$mount_root" || echo "recovery-update: failed to unmount $mount_root" >&2
    fi
    rmdir "$mount_root" 2>/dev/null || true
  fi
}

mount_target() {
  local device="$1"

  [[ -b $device ]] || return 0
  findmnt --noheadings --raw --source "$(readlink -f "$device")" --output TARGET 2>/dev/null || true
}

unmount_stale_disko_tree() {
  local recovery_target efi_target data_target

  recovery_target="$(mount_target "$recovery_device")"
  efi_target="$(mount_target "$recovery_efi_device")"
  data_target="$(mount_target "$data_device")"

  [[ -z $recovery_target || $recovery_target == "$disko_mount_root" ]] || \
    die "$recovery_device is already mounted at $recovery_target"
  [[ -z $efi_target || $efi_target == "$disko_mount_root/boot" ]] || \
    die "$recovery_efi_device is already mounted at $efi_target"
  [[ -z $data_target || $data_target == "/mnt/SN350" || $data_target == "$disko_mount_root/mnt/SN350" ]] || \
    die "$data_device is already mounted at $data_target"

  if [[ -n $recovery_target || -n $efi_target || $data_target == "$disko_mount_root/mnt/SN350" ]]; then
    echo "Removing the stale Disko mount tree at $disko_mount_root."
    [[ $data_target != "$disko_mount_root/mnt/SN350" ]] || umount "$data_target"
    [[ -z $efi_target ]] || umount "$efi_target"
    [[ -z $recovery_target ]] || umount "$recovery_target"
  fi
}

if [[ $EUID -ne 0 ]]; then
  sudo_wrapper="/run/wrappers/bin/sudo"
  [[ -x $sudo_wrapper ]] || die "NixOS sudo wrapper is unavailable: $sudo_wrapper"
  exec "$sudo_wrapper" -- "$0" "$@"
fi

trap cleanup EXIT

[[ -n ''${RECOVERY_SYSTEM:-} ]] || die "the recovery system closure was not provided"
[[ -b $recovery_device ]] || die "missing partition $recovery_device; follow recovery/README.md first"
[[ -b $recovery_efi_device ]] || die "missing partition $recovery_efi_device; follow recovery/README.md first"
[[ -r $password_hash ]] || die "missing decrypted root password hash: $password_hash"

filesystem_type="$(blkid -s TYPE -o value "$recovery_device")"
filesystem_label="$(blkid -s LABEL -o value "$recovery_device")"
[[ $filesystem_type == ext4 ]] || die "$recovery_device is $filesystem_type, expected ext4"
[[ $filesystem_label == NIXOS-RECOVERY ]] || die "$recovery_device has label $filesystem_label, expected NIXOS-RECOVERY"

efi_filesystem_type="$(blkid -s TYPE -o value "$recovery_efi_device")"
efi_filesystem_label="$(blkid -s LABEL -o value "$recovery_efi_device")"
[[ $efi_filesystem_type == vfat ]] || die "$recovery_efi_device is $efi_filesystem_type, expected vfat"
[[ $efi_filesystem_label == RECOVERYEFI ]] || die "$recovery_efi_device has label $efi_filesystem_label, expected RECOVERYEFI"

unmount_stale_disko_tree

mount_root="$(mktemp -d /tmp/nixos-recovery.XXXXXX)"
mount "$recovery_device" "$mount_root"
install -d -m 0700 "$mount_root/boot"
mount "$recovery_efi_device" "$mount_root/boot"

install -d -m 0700 "$mount_root/etc"
install -m 0600 "$password_hash" "$mount_root/etc/recovery-root-password-hash"

nixos-install \
  --root "$mount_root" \
  --system "$RECOVERY_SYSTEM" \
  --no-root-password \
  --no-channel-copy

nixos-enter --root "$mount_root" --command \
  'nix-env --profile /nix/var/nix/profiles/system --delete-generations old && nix-store --gc'

echo "Recovery root updated successfully."
echo "Boot it from the firmware menu by selecting the WD Green SN350."
