set -Eeuo pipefail

# Reads the main system's persisted journal without entering it. The persist
# subvolume is mounted read-only; Btrfs may still replay its own log after a
# crash, which keeps the last entries before the failure.
mount_root="/run/main-logs"
device=""
options=""

die() {
  echo "main-logs: $*" >&2
  exit 1
}

cleanup() {
  if mountpoint --quiet "$mount_root"; then
    umount "$mount_root" || echo "main-logs: failed to unmount $mount_root" >&2
  fi
}

[[ $EUID -eq 0 ]] || die "run this command as root"

while IFS=$'\t' read -r kind source mount_target mount_options; do
  if [[ $kind == btrfs && $mount_target == /persist ]]; then
    device="$source"
    options="$mount_options"
  fi
done <"$SYSTEM_CHROOT_MOUNTS"
[[ -n $device ]] || die "the main mount table has no /persist entry"
[[ -b $device ]] || die "main Btrfs device is unavailable: $device"

trap cleanup EXIT
mkdir -p "$mount_root"
mountpoint --quiet "$mount_root" && die "$mount_root is already a mount point"
mount -t btrfs -o "ro,$options" "$device" "$mount_root"

journal="$mount_root/var/log/journal"
[[ -d $journal ]] || die "the main system has no persisted journal in /persist/var/log/journal"

echo "Recent boots of the main system:"
journalctl --directory="$journal" --list-boots --no-pager | tail -n 10

# With --directory, a bare --boot means the recovery system's own boot, so
# select the main system's last boot by its ID.
last_boot="$(journalctl --directory="$journal" --list-boots --no-pager --quiet | awk 'END { print $2 }')"
[[ $last_boot =~ ^[0-9a-f]{32}$ ]] || die "could not read the last boot ID from the main journal"

echo
echo "Warnings and errors from the last main boot ($last_boot):"
# Saved to a file (for example to share with an assistant) it prints
# everything; in a terminal it opens a pager at the newest entries.
if [[ -t 1 ]]; then
  echo "Press q to close the log."
  read -r -p "Press Enter to open it. " _ || true
  journalctl --directory="$journal" --boot="$last_boot" --priority=warning --pager-end
else
  journalctl --directory="$journal" --boot="$last_boot" --priority=warning --no-pager
fi
