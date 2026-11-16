set -Eeuo pipefail

target="/mnt/system"
toplevel="/run/system-chroot/toplevel"
repo="/home/$RECOVERY_USERNAME/system-conf"
reinstall_bootloader=0
declare -a mounted_paths=()
declare -a btrfs_targets=() btrfs_options=()
declare -a bind_kinds=() bind_sources=() bind_targets=()
main_device=""
efi_device=""
efi_options=""

die() {
  echo "system-chroot: $*" >&2
  exit 1
}

cleanup() {
  local index path

  for ((index = ${#mounted_paths[@]} - 1; index >= 0; index--)); do
    path="${mounted_paths[$index]}"
    if mountpoint --quiet "$path"; then
      umount "$path" || echo "system-chroot: failed to unmount $path" >&2
    fi
  done
}

confirm() {
  local answer=""

  printf 'Type %s to continue, or anything else to cancel: ' "$1"
  read -r answer || true
  [[ $answer == "$1" ]] || die "cancelled"
}

track_mount() {
  mount "$@"
  mounted_paths+=("${*: -1}")
}

subvolume_of() {
  local option
  local -a options

  IFS=, read -ra options <<<"$1"
  for option in "${options[@]}"; do
    if [[ $option == subvol=* ]]; then
      option="${option#subvol=}"
      printf '%s\n' "${option#/}"
      return 0
    fi
  done
  return 1
}

# Absolute symlinks in the main root resolve against the recovery system, so a
# bind through one could cover a path outside the chroot.
crosses_symlink() {
  local path="$target" component
  local -a components

  IFS=/ read -ra components <<<"${1#/}"
  for component in "${components[@]}"; do
    path="$path/$component"
    [[ ! -L $path ]] || return 0
  done
  return 1
}

case $# in
  0) ;;
  1) [[ $1 == --reinstall-bootloader ]] || die "usage: system-chroot [--reinstall-bootloader]"; reinstall_bootloader=1 ;;
  *) die "usage: system-chroot [--reinstall-bootloader]" ;;
esac

trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "run this command as root"

while IFS=$'\t' read -r kind source mount_target options; do
  case $kind in
    btrfs)
      main_device="$source"
      btrfs_targets+=("$mount_target")
      btrfs_options+=("$options")
      ;;
    vfat)
      efi_device="$source"
      efi_options="$options"
      ;;
    dir | file)
      bind_kinds+=("$kind")
      bind_sources+=("$source")
      bind_targets+=("$mount_target")
      ;;
    *) die "unknown entry '$kind' in $SYSTEM_CHROOT_MOUNTS" ;;
  esac
done <"$SYSTEM_CHROOT_MOUNTS"
[[ ${btrfs_targets[0]:-} == / ]] || die "the mount table does not start with the main root"
[[ -b $main_device ]] || die "main Btrfs device is unavailable: $main_device"
[[ -b $efi_device ]] || die "main EFI device is unavailable: $efi_device"

mkdir -p "$target"
mountpoint --quiet "$target" && die "$target is already a mount point"
mkdir -p "$toplevel"
mountpoint --quiet "$toplevel" && die "$toplevel is already a mount point"

# The top level shows every subvolume, including the blanks the main initrd
# restores from.
track_mount -t btrfs -o subvolid=5,noatime "$main_device" "$toplevel"

declare -a missing=()
for options in "${btrfs_options[@]}"; do
  subvolume="$(subvolume_of "$options")" || die "a main Btrfs mount has no subvol= option: $options"
  if ! btrfs subvolume show "$toplevel/$subvolume" >/dev/null 2>&1; then
    [[ " $SYSTEM_CHROOT_ROLLBACK_SUBVOLUMES " == *" $subvolume "* ]] ||
      die "the main Btrfs filesystem has no '$subvolume' subvolume"
    btrfs subvolume show "$toplevel/$subvolume-blank" >/dev/null 2>&1 ||
      die "the main Btrfs filesystem has neither '$subvolume' nor '$subvolume-blank'"
    missing+=("$subvolume")
  fi
done

if ((${#missing[@]} > 0)); then
  echo "The main system is missing these subvolumes: ${missing[*]}."
  echo "Its boot-time rollback was probably interrupted after deleting them. Restoring"
  echo "them from their blank snapshots creates the same state the next main boot would."
  confirm RESTORE
  for subvolume in "${missing[@]}"; do
    btrfs subvolume snapshot "$toplevel/$subvolume-blank" "$toplevel/$subvolume"
  done
fi

track_mount -t btrfs -o "${btrfs_options[0]}" "$main_device" "$target"

# A root that was just rolled back is empty until the main stage 2 fills it.
# These directories and the NixOS marker live on that throwaway subvolume.
for mount_target in "${btrfs_targets[@]:1}" /boot; do
  mkdir -p "$target$mount_target"
done
mkdir -p "$target/etc"
[[ -e $target/etc/NIXOS ]] || touch "$target/etc/NIXOS"

for ((index = 1; index < ${#btrfs_targets[@]}; index++)); do
  track_mount -t btrfs -o "${btrfs_options[$index]}" "$main_device" "$target${btrfs_targets[$index]}"
done
track_mount -t vfat -o "$efi_options" "$efi_device" "$target/boot"

# Recreate the impermanence bind mounts, so the main system's activation, which
# nixos-enter runs, sees the persisted machine ID, user and group IDs, journal,
# and home files instead of the empty ephemeral copies.
bound=0
skipped=0
for index in "${!bind_kinds[@]}"; do
  source="$target${bind_sources[$index]}"
  destination="$target${bind_targets[$index]}"
  if crosses_symlink "${bind_sources[$index]}" || crosses_symlink "${bind_targets[$index]}"; then
    echo "system-chroot: not binding ${bind_targets[$index]} through a symlink" >&2
    skipped=$((skipped + 1))
    continue
  fi
  if [[ ${bind_kinds[$index]} == dir ]]; then
    if [[ ! -d $source ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$destination"
  else
    if [[ ! -f $source ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$(dirname "$destination")"
    [[ -e $destination ]] || touch "$destination"
  fi
  track_mount --bind "$source" "$destination"
  bound=$((bound + 1))
done
echo "Restored $bound persisted paths; $skipped were absent from /persist."

if ((reinstall_bootloader)); then
  generation="$(readlink "$target/nix/var/nix/profiles/system")" ||
    die "the main system has no current generation"
  system="$(readlink "$target/nix/var/nix/profiles/$generation")" ||
    die "the main system's $generation link is broken"
  echo "This reinstalls the main bootloader on $efi_device and rewrites its menu"
  echo "for the current generation, $generation:"
  echo "  $system"
  confirm REPAIR
  # The same step nixos-install uses to install a bootloader.
  NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root "$target" --command \
    '/nix/var/nix/profiles/system/bin/switch-to-configuration boot'
  echo "The main bootloader was reinstalled."
  exit 0
fi

echo "Entering the main NixOS installation."
if [[ -d $target$repo ]]; then
  echo "The flake is available at $repo."
else
  echo "system-chroot: the persisted flake repository is missing: $repo" >&2
fi
echo "The top-level Btrfs volume is mounted at $toplevel in the recovery system."
echo "Exit the shell to unmount the main system."

nixos-enter --root "$target"
