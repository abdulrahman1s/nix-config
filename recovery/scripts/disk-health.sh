set -Eeuo pipefail
shopt -s nullglob

die() {
  echo "disk-health: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "run this command as root"

lsblk --output NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL

# Whole disks only; /sys/block has no partition entries. Listing them here is
# more reliable than smartctl --scan, which can miss NVMe namespaces.
for entry in /sys/block/nvme*n* /sys/block/sd*; do
  device="/dev/${entry##*/}"
  echo
  echo "=== $device: $(lsblk --nodeps --noheadings --output MODEL,SIZE "$device")"
  # smartctl reports findings in its exit status bits, so a non-zero status is
  # shown instead of stopping the remaining disks.
  status=0
  smartctl --health --attributes "$device" || status=$?
  ((status == 0)) || echo "smartctl exited with status $status for $device; see 'man smartctl' (EXIT STATUS)."
done
