set -Eeuo pipefail

recovery_disk="/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b4056230e"
expected_model="WD Green SN350 1TB"
expected_serial="24301E803752"
confirmation="--confirm-erase-sn350"

die() {
  echo "recovery-partition: $*" >&2
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  sudo_wrapper="/run/wrappers/bin/sudo"
  [[ -x $sudo_wrapper ]] || die "NixOS sudo wrapper is unavailable: $sudo_wrapper"
  exec "$sudo_wrapper" -- "$0" "$@"
fi

[[ ''${1:-} == "$confirmation" ]] || die "this erases the SN350; rerun with $confirmation"
[[ $# -eq 1 ]] || die "unexpected arguments"
[[ -b $recovery_disk ]] || die "target disk is unavailable: $recovery_disk"

model="$(udevadm info --query=property --property=ID_MODEL --value "$recovery_disk")"
serial="$(udevadm info --query=property --property=ID_SERIAL_SHORT --value "$recovery_disk")"
[[ $model == "$expected_model" ]] || die "target model is '$model', expected '$expected_model'"
[[ $serial == "$expected_serial" ]] || die "target serial is '$serial', expected '$expected_serial'"

if lsblk --noheadings --raw --output MOUNTPOINTS "$recovery_disk" | grep --quiet '[^[:space:]]'; then
  die "the SN350 or one of its partitions is mounted; unmount it before continuing"
fi

echo "Verified target: $expected_model, serial $expected_serial"
echo "Disko will now erase and recreate only $recovery_disk."

"$RECOVERY_DISKO_SCRIPT"
"$RECOVERY_DISKO_UNMOUNT_SCRIPT"

echo "SN350 partitioning completed successfully."
