set -Eeuo pipefail

usage="usage: recovery-usb /dev/sdX [--with-logins]"
password_hash="/run/agenix/root-password-hash"
# The installed system takes about 7 GiB. This leaves room for nix shell and
# logs, and still accepts a drive sold as 16 GB.
min_size_gib=12
disk=""
erase=""
with_logins=false
mount_root=""

die() {
  echo "recovery-usb: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n $mount_root ]]; then
    if mountpoint --quiet "$mount_root/boot"; then
      umount "$mount_root/boot" || echo "recovery-usb: failed to unmount $mount_root/boot" >&2
    fi
    if mountpoint --quiet "$mount_root"; then
      umount "$mount_root" || echo "recovery-usb: failed to unmount $mount_root" >&2
    fi
    rmdir "$mount_root" 2>/dev/null || true
  fi
}

# --erase=NAME carries the typed confirmation across the sudo re-exec.
for arg in "$@"; do
  case $arg in
    --with-logins) with_logins=true ;;
    --erase=*) erase="${arg#--erase=}" ;;
    /dev/*)
      [[ -z $disk ]] || die "$usage"
      disk="$arg"
      ;;
    *) die "$usage" ;;
  esac
done

if [[ -z $disk ]]; then
  echo "$usage"
  echo
  echo "USB drives attached now:"
  lsblk --nodeps --paths --output NAME,TRAN,SIZE,MODEL,SERIAL | awk 'NR == 1 || $2 == "usb"'
  exit 1
fi

# These checks need no root, so they run before sudo asks for a password, and
# again as root.
[[ -b $disk ]] || die "$disk is not a block device"
disk="$(readlink -f "$disk")"
name="${disk##*/}"
[[ $(lsblk --nodeps --noheadings --raw --output TYPE "$disk") == disk ]] || \
  die "$disk is not a whole drive; give the drive itself, such as /dev/sdb"
transport="$(lsblk --nodeps --noheadings --raw --output TRAN "$disk")"
[[ $transport == usb ]] || \
  die "$disk is connected over ${transport:-an unknown bus}, not USB; this only writes to USB drives"
# A drive with any filesystem the main system mounts, such as a data drive in
# a USB enclosure, is never erased, even while it is unmounted.
if read -r device mount_point < <(
  lsblk --json --list --paths --output NAME,UUID,LABEL "$disk" |
    jq -r --slurpfile main "$RECOVERY_USB_PROTECTED" '
      .blockdevices[] as $device
      | $main[0][]
      | select(.device == "/dev/disk/by-uuid/\($device.uuid)" or .device == "/dev/disk/by-label/\($device.label)")
      | "\($device.name) \(.mountPoint)"'
); then
  die "$device holds the main system's $mount_point; this drive is never erased"
fi
if lsblk --noheadings --raw --output MOUNTPOINTS "$disk" | grep --quiet '[^[:space:]]'; then
  die "$disk has mounted partitions; unmount them first, for example with udisksctl unmount -b ${disk}1"
fi
size="$(lsblk --nodeps --noheadings --raw --bytes --output SIZE "$disk")"
((size >= min_size_gib * 1024 ** 3)) || \
  die "$disk holds $((size / 1024 ** 3)) GiB; the recovery needs at least $min_size_gib GiB"
# The installed system mounts its partitions by label, so another drive with
# the same labels could be mounted in their place.
if read -r device label < <(
  lsblk --json --list --paths --output NAME,PKNAME,LABEL |
    jq -r --arg disk "$disk" --arg root "$RECOVERY_USB_ROOT_LABEL" --arg efi "$RECOVERY_USB_EFI_LABEL" \
      '.blockdevices[] | select((.label == $root or .label == $efi) and .name != $disk and .pkname != $disk) | "\(.name) \(.label)"'
); then
  die "$device, on another drive, already has the label $label; disconnect that drive first"
fi

if [[ $erase != "$name" ]]; then
  echo
  lsblk --output NAME,SIZE,FSTYPE,LABEL,MODEL "$disk"
  echo
  echo "This erases everything on $disk and installs the recovery system on it."
  read -r -p "Type $name to continue: " answer || die "cancelled; nothing was changed"
  [[ $answer == "$name" ]] || die "cancelled; nothing was changed"
fi

if [[ $EUID -ne 0 ]]; then
  sudo_wrapper="/run/wrappers/bin/sudo"
  [[ -x $sudo_wrapper ]] || die "NixOS sudo wrapper is unavailable: $sudo_wrapper"
  args=("$disk" "--erase=$name")
  if $with_logins; then
    args+=(--with-logins)
  fi
  exec "$sudo_wrapper" -- "$0" "${args[@]}"
fi

trap cleanup EXIT

[[ -n ${RECOVERY_SYSTEM:-} ]] || die "the recovery system closure was not provided"
[[ -r $password_hash ]] || die "missing decrypted root password hash: $password_hash"

echo "Partitioning $disk."
# Partitions first, then the drive, so no old filesystem signature survives.
lsblk --list --noheadings --paths --output NAME "$disk" | tac | while read -r device; do
  wipefs --all --quiet "$device"
done
sgdisk --zap-all "$disk" >/dev/null
sgdisk \
  --new=1:0:+1G --typecode=1:EF00 --change-name=1:"$RECOVERY_USB_EFI_LABEL" \
  --new=2:0:0 --typecode=2:8300 --change-name=2:"$RECOVERY_USB_ROOT_LABEL" \
  "$disk" >/dev/null
udevadm settle

# The kernel adds "p" before the number when the drive's name ends in a digit.
if [[ $disk == *[0-9] ]]; then
  efi_partition="${disk}p1"
  root_partition="${disk}p2"
else
  efi_partition="${disk}1"
  root_partition="${disk}2"
fi
[[ -b $efi_partition && -b $root_partition ]] || die "the new partitions did not appear on $disk"

mkfs.fat -F 32 -n "$RECOVERY_USB_EFI_LABEL" "$efi_partition" >/dev/null
mkfs.ext4 -F -q -L "$RECOVERY_USB_ROOT_LABEL" "$root_partition"
udevadm settle

mount_root="$(mktemp -d /tmp/nixos-recovery-usb.XXXXXX)"
mount -o noatime "$root_partition" "$mount_root"
install -d -m 0700 "$mount_root/boot"
mount -o fmask=0077,dmask=0077 "$efi_partition" "$mount_root/boot"

# /etc must stay readable for normal users; the hash file itself is 0600.
install -d -m 0755 "$mount_root/etc"
install -m 0600 "$password_hash" "$mount_root/etc/recovery-root-password-hash"

echo "Installing the recovery system, about 7 GiB."
nixos-install \
  --root "$mount_root" \
  --system "$RECOVERY_SYSTEM" \
  --no-root-password \
  --no-channel-copy

if $with_logins; then
  copy_logins "$mount_root"
else
  echo "Left out the Claude Code and Codex logins, which anyone holding the drive could use."
  echo "Rerun with --with-logins to include them, or sign in on the drive itself."
fi

echo "Writing everything to the drive; slow drives can take a few minutes."
umount "$mount_root/boot" "$mount_root"
rmdir "$mount_root"
mount_root=""

echo "The recovery USB drive is ready on $disk."
echo "Boot it from the firmware's one-time boot menu."
