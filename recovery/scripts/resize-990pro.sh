# Grow the main Btrfs partition on the Samsung 990 PRO by taking space from the
# start of the ext4 data partition behind it. Run it from the SN350 recovery
# system while nothing on the 990 PRO is mounted.
#
# Each step is recorded in a state file on the recovery disk, so a stopped or
# interrupted run continues where it was when started again:
#   1. check both filesystems, then shrink ext4 in place with resize2fs;
#   2. move the start of the ext4 partition entry forward;
#   3. copy the ext4 image to that start, from its end toward its beginning, in
#      verified and checkpointed chunks;
#   4. check ext4 at its new location;
#   5. grow the Btrfs partition into the freed space, then grow Btrfs.
# Only a power loss or forced kill while resize2fs runs in step 1 can damage
# ext4. Ctrl+C asks the script to pause at the next safe point.

set -Eeuo pipefail
shopt -s nullglob

disk_link="${RESIZE_DISK_LINK:?}"
disk_model="${RESIZE_DISK_MODEL:?}"
disk_serial="${RESIZE_DISK_SERIAL:?}"
btrfs_uuid="${RESIZE_BTRFS_UUID:?}"
ext4_uuid="${RESIZE_EXT4_UUID:?}"
target_gib="${RESIZE_TARGET_GIB:?}"

btrfs_partno=2
ext4_partno=3
state_dir=/var/lib/resize-990pro
state_file="$state_dir/state"
log_file="$state_dir/log"
btrfs_mount=/run/resize-990pro/btrfs
# Offsets and chunks stay multiples of 1 MiB so O_DIRECT transfers are aligned.
# Copying from the end is only safe while the partition moves by at least one
# chunk: a chunk's destination then never overlaps source data not yet copied.
chunk_bytes=$((256 * 1024 * 1024))
sleep_units=(
  suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
  systemd-suspend.service systemd-hibernate.service systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service
)
sleep_dropin=50-resize-990pro.conf
state_keys=(
  version disk_serial target_gib
  btrfs_start btrfs_old_size btrfs_new_size
  ext4_old_start ext4_old_size ext4_new_start ext4_new_size
  ext4_block_size ext4_new_blocks
  phase resize_started move_remaining
)

declare -A state=()
disk=""
disk_name=""
lock_fd=""
inhibitor_pid=""
sleep_units_blocked=0
btrfs_mounted=0
copy_buffer=""
check_buffer=""
stop_requested=0
finished=0

log() {
  printf '[%(%F %T)T] %s\n' -1 "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'
}

on_error() {
  if ((stop_requested)); then
    log "Stopped on request while '$1' was running (line $3)."
  else
    log "ERROR: '$1' failed with exit status $2 (line $3)."
  fi
}

request_stop() {
  stop_requested=1
  log "Stop requested; pausing after the current step."
}

check_stop() {
  if ((stop_requested)); then
    log "Paused at phase '${state[phase]}'."
    exit 130
  fi
}

cleanup() {
  local status=$?
  set +e
  trap - ERR

  if ((btrfs_mounted)); then
    umount "$btrfs_mount" || log "WARNING: failed to unmount $btrfs_mount."
  fi
  [[ -z $copy_buffer ]] || rm -f -- "$copy_buffer"
  [[ -z $check_buffer ]] || rm -f -- "$check_buffer"
  if ((sleep_units_blocked)); then
    unblock_sleep_units
  fi
  [[ -z $inhibitor_pid ]] || kill "$inhibitor_pid" 2>/dev/null

  if ((!finished)) && [[ -n ${state[phase]:-} ]]; then
    if [[ ${state[phase]} == planned && ${state[resize_started]:-0} == 0 ]]; then
      log "Nothing has been resized yet. Run resize-990pro again to retry, or delete $state_dir to drop this plan."
    else
      log "The resize is incomplete (phase '${state[phase]}'). Run resize-990pro again to continue."
      log "Until it finishes, don't boot the main system or change the 990 PRO partitions by hand."
    fi
    log "Log: $log_file"
  fi
  exit "$status"
}

# Commands that must not be interrupted halfway ignore Ctrl+C and SIGTERM.
# Terminal hangups are ignored by the whole script. This only holds for
# synchronous subshells; bash restores SIGINT when an asynchronous one execs.
uninterruptible() {
  (
    trap '' INT TERM
    exec "$@"
  )
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

resolve_disk() {
  local model serial

  [[ -b $disk_link ]] || die "the Samsung 990 PRO ($disk_link) is not present"
  disk="$(readlink -f "$disk_link")"
  disk_name="${disk##*/}"
  [[ -d /sys/block/$disk_name ]] || die "$disk is not a whole disk"

  model="$(trim "$(<"/sys/block/$disk_name/device/model")")"
  serial="$(trim "$(<"/sys/block/$disk_name/device/serial")")"
  [[ $model == "$disk_model" ]] || die "$disk is '$model', expected '$disk_model'"
  [[ $serial == "$disk_serial" ]] || die "$disk has serial '$serial', expected '$disk_serial'"
  [[ $(<"/sys/block/$disk_name/queue/logical_block_size") == 512 ]] || die "$disk does not use 512-byte sectors"
}

# The state must survive a power loss and must not live on the disk it describes.
require_persistent_state_dir() {
  local source fstype source_name

  install -d -m 0700 "$state_dir"
  source="$(findmnt --noheadings --nofsroot --output SOURCE --target "$state_dir")"
  fstype="$(findmnt --noheadings --output FSTYPE --target "$state_dir")"
  case $fstype in
    ext4 | xfs | btrfs | f2fs) ;;
    *) die "$state_dir is on $fstype; run this from the installed recovery system so the progress survives a reboot" ;;
  esac
  [[ -b $source ]] || die "$state_dir is not backed by a block device"
  source_name="$(basename "$(readlink -f "$source")")"
  if [[ $source_name == "$disk_name" || -e /sys/block/$disk_name/$source_name ]]; then
    die "$state_dir is on the 990 PRO itself"
  fi
}

partition_dirs() {
  local dir
  for dir in "/sys/block/$disk_name/$disk_name"*; do
    if [[ -r $dir/partition ]]; then
      printf '%s\n' "$dir"
    fi
  done
}

part_device() {
  local dir
  while read -r dir; do
    if [[ $(<"$dir/partition") == "$1" ]]; then
      printf '/dev/%s\n' "${dir##*/}"
      return 0
    fi
  done < <(partition_dirs)
  return 1
}

# Partition start and size in sectors as the running kernel sees them.
kernel_geometry() {
  local dir
  while read -r dir; do
    if [[ $(<"$dir/partition") == "$1" ]]; then
      printf '%s %s\n' "$(<"$dir/start")" "$(<"$dir/size")"
      return 0
    fi
  done < <(partition_dirs)
  return 1
}

# Partition start and size in sectors as written in the on-disk table.
disk_geometry() {
  partx --show --noheadings --output START,SECTORS --nr "$1" "$disk" | awk '{ print $1, $2 }'
}

normalized_table() {
  sfdisk --dump "$disk" | sed -E 's/=[[:space:]]+/=/g'
}

expected_geometry() {
  case $1-$2 in
    btrfs-old) printf '%s %s\n' "${state[btrfs_start]}" "${state[btrfs_old_size]}" ;;
    btrfs-new) printf '%s %s\n' "${state[btrfs_start]}" "${state[btrfs_new_size]}" ;;
    ext4-old) printf '%s %s\n' "${state[ext4_old_start]}" "${state[ext4_old_size]}" ;;
    ext4-new) printf '%s %s\n' "${state[ext4_new_start]}" "${state[ext4_new_size]}" ;;
  esac
}

# Require both partitions at the recorded old or new positions, on disk and in
# the kernel, before a step touches them.
require_geometry() {
  local btrfs ext4

  btrfs="$(expected_geometry btrfs "$1")"
  ext4="$(expected_geometry ext4 "$2")"
  if [[ $(disk_geometry "$btrfs_partno") != "$btrfs" || $(disk_geometry "$ext4_partno") != "$ext4" ]]; then
    die "the partition table does not match the recorded state for phase '${state[phase]}'; not touching anything"
  fi
  if [[ $(kernel_geometry "$btrfs_partno" || true) != "$btrfs" || $(kernel_geometry "$ext4_partno" || true) != "$ext4" ]]; then
    die "the kernel uses an outdated partition table; reboot into the recovery system and run resize-990pro again"
  fi
}

probe() {
  blkid --probe --match-tag "$2" --output value "$1" 2>/dev/null || true
}

require_filesystem() {
  if [[ $(probe "$1" TYPE) != "$2" || $(probe "$1" UUID) != "$3" ]]; then
    die "$1 does not hold the expected $2 filesystem ($3)"
  fi
}

ext4_field() {
  dumpe2fs -h "$1" 2>/dev/null | awk -F ':[[:space:]]+' -v key="$2" '$1 == key { print $2; exit }'
}

require_unused() {
  local dir name holders
  local -a dirs

  mapfile -t dirs < <(partition_dirs)
  for dir in "/sys/block/$disk_name" "${dirs[@]}"; do
    name="${dir##*/}"
    if findmnt --noheadings --source "/dev/$name" >/dev/null; then
      die "/dev/$name is mounted; unmount it first (findmnt /dev/$name)"
    fi
    if grep -q "^/dev/${name}[[:space:]]" /proc/swaps; then
      die "/dev/$name is in use as swap"
    fi
    holders=("$dir"/holders/*)
    ((${#holders[@]} == 0)) || die "/dev/$name is held by ${holders[*]##*/}"
    [[ ! -d /proc/fs/ext4/$name ]] || die "/dev/$name has a mounted ext4 filesystem"
  done
  [[ ! -d /sys/fs/btrfs/$btrfs_uuid ]] || die "the main Btrfs filesystem ($btrfs_uuid) is mounted; unmount it first"
}

# An exclusive BSD lock on the whole disk keeps udev, and through it udisks,
# from probing or mounting partitions while they are being changed.
lock_disk() {
  exec {lock_fd}<"$disk"
  flock --exclusive --timeout 30 "$lock_fd" || die "could not lock $disk"
}

check_health() {
  local health

  health="$(smartctl -H "$disk" 2>&1 || true)"
  if grep -q 'result: FAILED' <<<"$health"; then
    die "SMART reports the 990 PRO as failing; back up its data instead of resizing it"
  fi
  grep -q 'result: PASSED' <<<"$health" || log "WARNING: could not read the SMART health of $disk."
}

check_power() {
  local supply battery=0 mains=0

  for supply in /sys/class/power_supply/*; do
    case "$(<"$supply/type")" in
      Battery) battery=1 ;;
      Mains | USB*)
        if [[ -r $supply/online && $(<"$supply/online") == 1 ]]; then
          mains=1
        fi
        ;;
    esac
  done
  ((battery == 0 || mains == 1)) || die "the computer is running on battery; connect the charger first"
}

start_sleep_inhibitor() {
  local attempt unit

  # The holder runs in its own session so Ctrl+C in the terminal cannot end it
  # early. tail exits as soon as this script does, even after a forced kill,
  # which releases the inhibitor lock with it.
  setsid systemd-inhibit \
    --what=sleep:idle:shutdown:handle-power-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch \
    --who=resize-990pro --why="Resizing the Samsung 990 PRO partitions" --mode=block \
    tail --pid="$$" --follow /dev/null </dev/null >/dev/null 2>&1 {lock_fd}<&- &
  inhibitor_pid=$!
  for attempt in {1..50}; do
    if systemd-inhibit --list --no-pager 2>/dev/null | grep -q resize-990pro; then
      break
    fi
    ((attempt < 50)) || die "could not block sleep and shutdown with systemd-inhibit"
    sleep 0.1
  done

  # Root can start the sleep units past the inhibitor, so they also refuse
  # explicit starts until this script exits or the system reboots. NixOS links
  # units into /etc/systemd/system, which outranks the /run directory used by
  # `systemctl mask --runtime`; drop-ins are merged from every directory.
  sleep_units_blocked=1
  for unit in "${sleep_units[@]}"; do
    install -d "/run/systemd/system/$unit.d"
    printf '[Unit]\nRefuseManualStart=yes\n' >"/run/systemd/system/$unit.d/$sleep_dropin"
  done
  if ! systemctl daemon-reload; then
    log "WARNING: could not reload systemd; relying on the systemd-inhibit lock alone."
  fi
  log "Sleep, suspend, hibernation and shutdown requests are blocked until this finishes."
}

unblock_sleep_units() {
  local unit

  for unit in "${sleep_units[@]}"; do
    rm -f -- "/run/systemd/system/$unit.d/$sleep_dropin"
    rmdir --ignore-fail-on-non-empty "/run/systemd/system/$unit.d" 2>/dev/null
  done
  systemctl daemon-reload || log "WARNING: could not reload systemd after unblocking the sleep units."
}

confirm() {
  local answer=""

  printf 'Type %s to continue, or anything else to cancel: ' "$1"
  read -r answer || true
  if [[ $answer != "$1" ]] || ((stop_requested)); then
    log "Cancelled."
    exit 1
  fi
}

save_state() {
  local key

  for key in "${state_keys[@]}"; do
    printf '%s=%s\n' "$key" "${state[$key]}"
  done >"$state_file.tmp"
  uninterruptible sync "$state_file.tmp"
  uninterruptible mv -f "$state_file.tmp" "$state_file"
  uninterruptible sync "$state_dir"
}

load_state() {
  local key value

  state=()
  while IFS='=' read -r key value; do
    [[ $key =~ ^[a-z0-9_]+$ && $value =~ ^[A-Za-z0-9._-]*$ ]] || die "$state_file is corrupt"
    state[$key]=$value
  done <"$state_file"
  for key in "${state_keys[@]}"; do
    [[ -n ${state[$key]+set} ]] || die "$state_file is missing '$key'"
    case $key in
      disk_serial | phase) ;;
      *) [[ ${state[$key]} =~ ^[0-9]+$ ]] || die "$state_file has a non-numeric '$key'" ;;
    esac
  done
  [[ ${state[version]} == 1 ]] || die "$state_file has an unknown version"
  [[ ${state[disk_serial]} == "$disk_serial" ]] || die "$state_file belongs to another disk"
}

set_phase() {
  state[phase]=$1
  save_state
  log "Phase: $1"
}

plan_resize() {
  local btrfs_dev ext4_dev btrfs_start btrfs_size ext4_start ext4_size last_start btrfs_devices
  local target_size delta new_start new_size
  local block_size block_count free_blocks reserved_blocks blocks_per_group inode_blocks
  local new_blocks removed_groups free_after reserved_after usable_after value

  btrfs_dev="$(part_device "$btrfs_partno")" || die "partition $btrfs_partno is missing on $disk"
  ext4_dev="$(part_device "$ext4_partno")" || die "partition $ext4_partno is missing on $disk"
  read -r btrfs_start btrfs_size < <(disk_geometry "$btrfs_partno")
  read -r ext4_start ext4_size < <(disk_geometry "$ext4_partno")
  for value in "$btrfs_start" "$btrfs_size" "$ext4_start" "$ext4_size"; do
    [[ $value =~ ^[0-9]+$ ]] || die "could not read the partition table of $disk"
  done
  if [[ $(kernel_geometry "$btrfs_partno") != "$btrfs_start $btrfs_size" || $(kernel_geometry "$ext4_partno") != "$ext4_start $ext4_size" ]]; then
    die "the kernel uses an outdated partition table; reboot and run resize-990pro again"
  fi
  require_filesystem "$btrfs_dev" btrfs "$btrfs_uuid"
  require_filesystem "$ext4_dev" ext4 "$ext4_uuid"
  ((btrfs_start + btrfs_size == ext4_start)) || die "the ext4 partition does not start right after the Btrfs partition"
  last_start="$(partx --show --noheadings --output START "$disk" | awk '{ print $1 }' | sort -n | tail -n 1)"
  ((last_start == ext4_start)) || die "the ext4 partition is not the last partition on $disk"
  btrfs_devices="$(btrfs filesystem show --raw "$btrfs_dev" | awk '/Total devices/ { print $3 }')"
  [[ $btrfs_devices == 1 ]] || die "the main Btrfs filesystem spans $btrfs_devices devices; expected 1"

  target_size=$((target_gib * 2097152))
  if ((btrfs_size >= target_size)); then
    log "The Btrfs partition is already $(gib $((btrfs_size * 512))); nothing to do."
    finished=1
    exit 0
  fi
  delta=$((target_size - btrfs_size))
  new_start=$((ext4_start + delta))
  new_size=$((ext4_size - delta))
  ((delta % 2048 == 0 && ext4_start % 2048 == 0 && new_size % 2048 == 0)) || die "the partitions are not aligned to 1 MiB"
  ((new_size > 0)) || die "the ext4 partition is smaller than the requested growth"
  ((delta * 512 >= chunk_bytes)) || die "the Btrfs partition must grow by at least $((chunk_bytes / 1048576)) MiB"

  block_size="$(ext4_field "$ext4_dev" 'Block size')"
  block_count="$(ext4_field "$ext4_dev" 'Block count')"
  free_blocks="$(ext4_field "$ext4_dev" 'Free blocks')"
  reserved_blocks="$(ext4_field "$ext4_dev" 'Reserved block count')"
  blocks_per_group="$(ext4_field "$ext4_dev" 'Blocks per group')"
  inode_blocks="$(ext4_field "$ext4_dev" 'Inode blocks per group')"
  for value in "$block_size" "$block_count" "$free_blocks" "$reserved_blocks" "$blocks_per_group" "$inode_blocks"; do
    [[ $value =~ ^[0-9]+$ ]] || die "could not read the ext4 superblock of $ext4_dev"
  done
  ((block_count * block_size <= ext4_size * 512)) || die "ext4 is larger than its partition"
  ((new_size * 512 % block_size == 0)) || die "the new ext4 size is not a whole number of blocks"
  new_blocks=$((new_size * 512 / block_size))

  # Shrinking drops whole block groups, which also frees their inode tables
  # and bitmaps. resize2fs keeps the root reserve at the same percentage.
  removed_groups=$(((block_count + blocks_per_group - 1) / blocks_per_group - (new_blocks + blocks_per_group - 1) / blocks_per_group))
  free_after=$((free_blocks - (block_count - new_blocks) + removed_groups * (inode_blocks + 2)))
  reserved_after=$((reserved_blocks * new_blocks / block_count))
  usable_after=$((free_after > reserved_after ? free_after - reserved_after : 0))
  ((free_after * block_size >= 4 * 1073741824)) ||
    die "ext4 would have only $(gib $((free_after * block_size))) free after shrinking; free up space on it first"

  log "Plan for $disk ($disk_model, serial $disk_serial):"
  log "  Btrfs partition $btrfs_partno (/, /home, /nix, /persist): $(gib $((btrfs_size * 512))) -> $(gib $((target_size * 512)))"
  log "  ext4 partition $ext4_partno (/mnt/990Pro): $(gib $((ext4_size * 512))) -> $(gib $((new_size * 512)))"
  log "  ext4 free space afterwards: about $(gib $((free_after * block_size))), of which about $(gib $((usable_after * block_size))) is usable"
  log "    by normal users ($((reserved_blocks * 100 / block_count))% of ext4 stays reserved for root)."
  log "  The ext4 data copy moves $(gib $((new_size * 512))); at about 1 GiB/s that takes roughly $((new_size * 512 / 1073741824 / 60 + 1)) minutes,"
  log "  plus a few minutes for each filesystem check and for resize2fs."
  log ""
  log "Keep the computer powered. A power loss while resize2fs shrinks ext4 can damage it;"
  log "every other step resumes safely when resize-990pro is run again."
  log "Back up anything on /mnt/990Pro that you cannot afford to lose before continuing."
  check_health
  check_power
  confirm RESIZE

  state=(
    [version]=1
    [disk_serial]="$disk_serial"
    [target_gib]="$target_gib"
    [btrfs_start]="$btrfs_start"
    [btrfs_old_size]="$btrfs_size"
    [btrfs_new_size]="$target_size"
    [ext4_old_start]="$ext4_start"
    [ext4_old_size]="$ext4_size"
    [ext4_new_start]="$new_start"
    [ext4_new_size]="$new_size"
    [ext4_block_size]="$block_size"
    [ext4_new_blocks]="$new_blocks"
    [phase]=planned
    [resize_started]=0
    [move_remaining]=$((new_size * 512))
  )
}

# Write one partition's new start and size, then require the table to match
# the previous one in everything else, including UUIDs, types, and names.
write_partition() {
  local number="$1" start="$2" size="$3" current before expected

  current="$(disk_geometry "$number")"
  before="$(normalized_table)"
  expected="$(printf '%s\n' "$before" | awk -v old="start=${current% *}," -v new="start=$start, size=$size," '
    / : start=/ && index($0, old) { sub(/start=[0-9]+, size=[0-9]+,/, new) }
    { print }
  ')"
  [[ $expected != "$before" ]] || die "could not find partition $number in the sfdisk dump of $disk"
  log "Writing partition $number: start sector $start, $size sectors."
  if ! printf 'start=%s, size=%s\n' "$start" "$size" |
    uninterruptible sfdisk --quiet --lock=no --wipe=never --wipe-partitions=never -N "$number" "$disk"; then
    log "WARNING: sfdisk reported a problem; checking the partition table."
  fi
  sync
  if [[ $(normalized_table) != "$expected" ]]; then
    printf '%s\n' "$expected" >"$state_dir/partition-table-expected.sfdisk"
    die "the partition table differs from $state_dir/partition-table-expected.sfdisk after writing partition $number"
  fi
  sync_kernel_partition "$number" "$start" "$size"
}

sync_kernel_partition() {
  [[ $(kernel_geometry "$1" || true) == "$2 $3" ]] && return 0
  blockdev --rereadpt "$disk" 2>/dev/null || partx --update --nr "$1" "$disk" 2>/dev/null || true
  [[ $(kernel_geometry "$1" || true) == "$2 $3" ]] ||
    die "the kernel still uses the old layout of partition $1; reboot into the recovery system and run resize-990pro again"
}

check_ext4_readonly() {
  local status=0

  uninterruptible e2fsck -f -n -C 0 "$1" || status=$?
  ((status == 0)) || die "$2"
}

shrink_ext4() {
  local device blocks minimum margin status=0

  require_geometry old old
  device="$(part_device "$ext4_partno")"
  require_filesystem "$device" ext4 "$ext4_uuid"
  blocks="$(ext4_field "$device" 'Block count')"

  if ((blocks != state[ext4_new_blocks])); then
    if [[ ${state[resize_started]} == 1 ]]; then
      log "The previous resize2fs run did not finish. Checking ext4 read-only first..."
      check_ext4_readonly "$device" "ext4 has errors after the interrupted resize2fs run. Repair it with 'e2fsck -f $device', then run resize-990pro again."
    fi

    log "Checking ext4 (e2fsck -f -p); this can take several minutes..."
    uninterruptible e2fsck -f -p -C 0 "$device" || status=$?
    # Exit statuses 1 and 2 mean e2fsck fixed something safely.
    (((status & ~3) == 0)) ||
      die "e2fsck could not repair ext4 automatically (exit status $status). Repair it with 'e2fsck -f $device', then run resize-990pro again."

    log "Checking Btrfs (btrfs check --readonly)..."
    btrfs check --readonly "$(part_device "$btrfs_partno")" ||
      die "btrfs check found problems on the main Btrfs filesystem; nothing has been resized"

    minimum="$(resize2fs -P "$device" 2>/dev/null | awk -F ':[[:space:]]*' '/minimum size/ { print $2 }')"
    [[ $minimum =~ ^[0-9]+$ ]] || die "could not read the minimum ext4 size from resize2fs -P"
    margin=$((1073741824 / state[ext4_block_size]))
    ((minimum + margin <= state[ext4_new_blocks])) ||
      die "ext4 needs at least $(gib $(((minimum + margin) * state[ext4_block_size]))) but would get $(gib $((state[ext4_new_blocks] * state[ext4_block_size]))); free up space on it first"

    state[resize_started]=1
    save_state
    log "Shrinking ext4 to $(gib $((state[ext4_new_size] * 512))) with resize2fs. Keep the computer powered; Ctrl+C waits until it finishes."
    uninterruptible resize2fs -p "$device" "${state[ext4_new_blocks]}" ||
      die "resize2fs failed. Check ext4 with 'e2fsck -f -n $device' before doing anything else."
    sync
    blockdev --flushbufs "$device"
    blocks="$(ext4_field "$device" 'Block count')"
    ((blocks == state[ext4_new_blocks])) || die "resize2fs finished but ext4 has $blocks blocks instead of ${state[ext4_new_blocks]}"
  fi

  log "Checking the shrunk ext4 (e2fsck -f -n)..."
  check_ext4_readonly "$device" "e2fsck reports problems after shrinking ext4. The partition table is unchanged; repair it with 'e2fsck -f $device', then run resize-990pro again."
  set_phase ext4-shrunk
}

move_ext4_partition() {
  local current device blocks

  [[ $(disk_geometry "$btrfs_partno") == "$(expected_geometry btrfs old)" ]] ||
    die "the Btrfs partition is not at its recorded position; not touching anything"
  current="$(disk_geometry "$ext4_partno")"
  if [[ $current == "$(expected_geometry ext4 old)" ]]; then
    device="$(part_device "$ext4_partno")"
    require_filesystem "$device" ext4 "$ext4_uuid"
    blocks="$(ext4_field "$device" 'Block count')"
    ((blocks == state[ext4_new_blocks])) || die "ext4 has $blocks blocks instead of ${state[ext4_new_blocks]}; refusing to move its partition"
    log "Moving the start of partition $ext4_partno forward by $(gib $(((state[ext4_new_start] - state[ext4_old_start]) * 512)))."
    write_partition "$ext4_partno" "${state[ext4_new_start]}" "${state[ext4_new_size]}"
  elif [[ $current != "$(expected_geometry ext4 new)" ]]; then
    die "partition $ext4_partno is at an unexpected position ($current); not touching anything"
  fi
  sync_kernel_partition "$ext4_partno" "${state[ext4_new_start]}" "${state[ext4_new_size]}"
  set_phase copying
}

# Copy one chunk between whole-disk byte offsets and read it back. Retrying is
# safe because the chunk's own source is not overwritten by its destination.
copy_chunk() {
  uninterruptible dd if="$disk" of="$copy_buffer" bs=16M iflag=direct,fullblock,skip_bytes,count_bytes \
    skip="$1" count="$3" status=none || return 1
  [[ $(uninterruptible stat --format=%s "$copy_buffer") == "$3" ]] || return 1
  uninterruptible dd if="$copy_buffer" of="$disk" bs=16M oflag=direct,seek_bytes \
    seek="$2" conv=notrunc,fsync status=none || return 1
  uninterruptible dd if="$disk" of="$check_buffer" bs=16M iflag=direct,fullblock,skip_bytes,count_bytes \
    skip="$2" count="$3" status=none || return 1
  uninterruptible cmp --silent "$copy_buffer" "$check_buffer"
}

copy_ext4() {
  local source_base destination_base total remaining start length attempt
  local started=$SECONDS last_report=$SECONDS copied=0 elapsed rate minutes_left

  require_geometry old new
  source_base=$((state[ext4_old_start] * 512))
  destination_base=$((state[ext4_new_start] * 512))
  total=$((state[ext4_new_size] * 512))
  remaining=${state[move_remaining]}
  copy_buffer="$(mktemp /dev/shm/resize-990pro.XXXXXX)"
  check_buffer="$(mktemp /dev/shm/resize-990pro.XXXXXX)"

  log "Copying ext4 to its new location: $(gib "$remaining") of $(gib "$total") left. Ctrl+C pauses safely."
  while ((remaining > 0)); do
    start=$((remaining > chunk_bytes ? remaining - chunk_bytes : 0))
    length=$((remaining - start))
    for attempt in 1 2 3; do
      copy_chunk "$((source_base + start))" "$((destination_base + start))" "$length" && break
      ((attempt < 3)) || die "could not copy and verify ext4 bytes $start-$remaining after 3 attempts; the disk may be failing"
      log "WARNING: the chunk at ext4 offset $start did not verify; retrying."
    done
    remaining=$start
    state[move_remaining]=$remaining
    save_state
    copied=$((copied + length))

    if ((SECONDS - last_report >= 15 || remaining == 0)); then
      last_report=$SECONDS
      elapsed=$((SECONDS - started > 0 ? SECONDS - started : 1))
      rate=$((copied / elapsed))
      minutes_left=$((rate > 0 ? remaining / rate / 60 : 0))
      log "Copied $(gib $((total - remaining))) of $(gib "$total") ($(((total - remaining) * 100 / total))%), $((rate / 1048576)) MiB/s, about $minutes_left min left."
    fi
    check_stop
  done
  set_phase copied
}

check_moved_ext4() {
  local device blocks

  require_geometry old new
  device="$(part_device "$ext4_partno")"
  blockdev --flushbufs "$disk"
  blockdev --flushbufs "$device"
  require_filesystem "$device" ext4 "$ext4_uuid"
  blocks="$(ext4_field "$device" 'Block count')"
  ((blocks == state[ext4_new_blocks])) || die "ext4 at its new location has $blocks blocks instead of ${state[ext4_new_blocks]}"
  log "Checking ext4 at its new location (e2fsck -f -n)..."
  check_ext4_readonly "$device" "ext4 at its new location has errors. Keep $state_dir and the log, review the e2fsck output, and only then repair it with 'e2fsck -f $device'."
  set_phase ext4-checked
}

grow_btrfs_partition() {
  local current

  [[ $(disk_geometry "$ext4_partno") == "$(expected_geometry ext4 new)" ]] ||
    die "the ext4 partition is not at its recorded new position; not touching anything"
  current="$(disk_geometry "$btrfs_partno")"
  if [[ $current == "$(expected_geometry btrfs old)" ]]; then
    log "Growing partition $btrfs_partno into the freed space."
    write_partition "$btrfs_partno" "${state[btrfs_start]}" "${state[btrfs_new_size]}"
  elif [[ $current != "$(expected_geometry btrfs new)" ]]; then
    die "partition $btrfs_partno has an unexpected layout ($current); not touching anything"
  fi
  sync_kernel_partition "$btrfs_partno" "${state[btrfs_start]}" "${state[btrfs_new_size]}"
  require_filesystem "$(part_device "$btrfs_partno")" btrfs "$btrfs_uuid"
  set_phase btrfs-partition-grown
}

grow_btrfs() {
  local device devid size

  require_geometry new new
  device="$(part_device "$btrfs_partno")"
  install -d -m 0700 "$btrfs_mount"
  mount -t btrfs -o subvolid=5,noatime "$device" "$btrfs_mount"
  btrfs_mounted=1

  devid="$(btrfs filesystem show --raw "$btrfs_mount" | awk '$1 == "devid" { print $2 }')"
  [[ $devid =~ ^[0-9]+$ ]] || die "expected exactly one Btrfs device, found '$devid'"
  log "Growing Btrfs to fill its partition."
  uninterruptible btrfs filesystem resize "$devid:max" "$btrfs_mount"
  size="$(btrfs filesystem show --raw "$btrfs_mount" | awk '$1 == "devid" { print $4 }')"
  ((size == state[btrfs_new_size] * 512)) || die "Btrfs reports a device size of $size bytes, expected $((state[btrfs_new_size] * 512))"

  sync
  umount "$btrfs_mount"
  btrfs_mounted=0
  set_phase "done"
}

report() {
  local device block_size free_blocks reserved_blocks

  device="$(part_device "$ext4_partno")"
  block_size="$(ext4_field "$device" 'Block size')"
  free_blocks="$(ext4_field "$device" 'Free blocks')"
  reserved_blocks="$(ext4_field "$device" 'Reserved block count')"
  finished=1
  log "Finished. Btrfs now has $(gib $((state[btrfs_new_size] * 512))) and ext4 $(gib $((state[ext4_new_size] * 512)))."
  log "ext4 has $(gib $((free_blocks * block_size))) free, $(gib $((reserved_blocks * block_size))) of it reserved for root."
  log "To shrink that reserve to 1%: tune2fs -m 1 /dev/disk/by-uuid/$ext4_uuid"
  log "Both filesystems keep their UUIDs, so the main system needs no configuration change. Reboot into it."
}

main() {
  local fresh=0

  resolve_disk
  require_persistent_state_dir
  exec > >(
    trap '' TERM
    exec tee --ignore-interrupts -a "$log_file"
  ) 2>&1
  log "resize-990pro started for $disk ($disk_model, serial $disk_serial)."
  require_unused
  lock_disk

  if [[ -f $state_file ]]; then
    load_state
    if [[ ${state[phase]} == "done" ]]; then
      finished=1
      log "The resize already finished. To plan a new one, delete $state_dir first."
      exit 0
    fi
    [[ ${state[target_gib]} == "$target_gib" ]] ||
      die "the unfinished resize in $state_file targets ${state[target_gib]} GiB, not $target_gib GiB"
    log "Found an unfinished resize at phase '${state[phase]}'."
    check_power
    confirm RESUME
  else
    plan_resize
    fresh=1
  fi

  start_sleep_inhibitor
  if ((fresh)); then
    sfdisk --dump "$disk" >"$state_dir/partition-table-before.sfdisk"
    sync "$state_dir/partition-table-before.sfdisk"
    log "Saved the original partition table to $state_dir/partition-table-before.sfdisk."
    set_phase planned
  fi

  while [[ ${state[phase]} != "done" ]]; do
    check_stop
    case ${state[phase]} in
      planned) shrink_ext4 ;;
      ext4-shrunk) move_ext4_partition ;;
      copying) copy_ext4 ;;
      copied) check_moved_ext4 ;;
      ext4-checked) grow_btrfs_partition ;;
      btrfs-partition-grown) grow_btrfs ;;
      *) die "unknown phase '${state[phase]}' in $state_file" ;;
    esac
  done
  report
}

if [[ $EUID -ne 0 ]]; then
  sudo_wrapper="/run/wrappers/bin/sudo"
  [[ -x $sudo_wrapper ]] || die "run this command as root"
  exec "$sudo_wrapper" -- "$0" "$@"
fi

trap cleanup EXIT
trap 'on_error "$BASH_COMMAND" "$?" "$LINENO"' ERR
trap request_stop INT TERM
trap '' HUP QUIT

main "$@"
