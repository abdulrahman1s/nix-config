set -Eeuo pipefail

main_device="/dev/disk/by-uuid/ddb4bdb8-c522-4420-ba2d-ace00fc2054b"
efi_device="/dev/disk/by-uuid/FE76-C46F"
target="/mnt/system"
declare -a mounted_paths=()

die() {
  echo "system-chroot: $*" >&2
  exit 1
}

cleanup() {
  local index path

  for ((index = ''${#mounted_paths[@]} - 1; index >= 0; index--)); do
    path="''${mounted_paths[$index]}"
    if mountpoint --quiet "$path"; then
      umount "$path" || echo "system-chroot: failed to unmount $path" >&2
    fi
  done
}

trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "run this command as root"
[[ -b $main_device ]] || die "main Btrfs device is unavailable: $main_device"
[[ -b $efi_device ]] || die "main EFI device is unavailable: $efi_device"

mkdir -p "$target"
mountpoint --quiet "$target" && die "$target is already a mount point"

mount -t btrfs -o subvol=root,compress=zstd:1,noatime "$main_device" "$target"
mounted_paths+=("$target")

for subvolume in nix home persist; do
  mount_path="$target/$subvolume"
  [[ -d $mount_path ]] || die "the main root is missing /$subvolume"
  mount -t btrfs -o "subvol=$subvolume,compress=zstd:1,noatime" "$main_device" "$mount_path"
  mounted_paths+=("$mount_path")
done

[[ -d $target/boot ]] || die "the main root is missing /boot"
mount -t vfat -o fmask=0077,dmask=0077 "$efi_device" "$target/boot"
mounted_paths+=("$target/boot")

repo_source="$target/persist/home/$RECOVERY_USERNAME/system-conf"
repo_target="$target/home/$RECOVERY_USERNAME/system-conf"
[[ -d $repo_source ]] || die "persisted flake repository is missing: $repo_source"
mkdir -p "$repo_target"
mount --bind "$repo_source" "$repo_target"
mounted_paths+=("$repo_target")

echo "Entering the main NixOS installation."
echo "The flake is available at /home/$RECOVERY_USERNAME/system-conf."
echo "Exit the shell to unmount the main system."

nixos-enter --root "$target"
