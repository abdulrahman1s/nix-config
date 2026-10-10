#!/usr/bin/env bash

# MangoHud reads exec output after only 50 ms. Keep NVIDIA queries out of that
# path so a slow nvidia-smi call cannot shift later values into WireView cells.
nvidia_smi=/nix/var/nix/profiles/system/sw/bin/nvidia-smi
cache_dir=/run/user/$UID
cache_file=$cache_dir/mangohud-gpu-stats

format_gib() {
  local tenths=$((($1 * 10 + 512) / 1024))
  printf '%d.%d GiB\n' "$((tenths / 10))" "$((tenths % 10))"
}

refresh_cache() {
  local now fan memory line pid mib tmp
  local -a fields
  local -A memory_by_pid=()

  # flock also releases the lock if a refresh is interrupted.
  exec 9>"$cache_file.lock" || return
  /nix/var/nix/profiles/system/sw/bin/flock -n 9 || return
  printf -v now '%(%s)T' -1
  printf '%s\n' "$now" > "$cache_file.attempt"

  IFS=, read -r fan memory < <(
    "$nvidia_smi" --query-gpu=fan.speed,memory.used --format=csv,noheader,nounits 2>/dev/null
  )
  fan=${fan//[[:space:]]/}
  memory=${memory//[[:space:]]/}
  [[ $fan =~ ^[0-9]+$ && $memory =~ ^[0-9]+$ ]] || return

  # The regular process table includes graphics-only games, unlike the
  # compute-apps CSV query.
  while IFS= read -r line; do
    read -ra fields <<< "$line"
    ((${#fields[@]} >= 7)) || continue
    pid=${fields[4]}
    mib=${fields[${#fields[@]}-2]}
    if [[ $pid =~ ^[0-9]+$ && $mib =~ ^([0-9]+)MiB$ ]]; then
      memory_by_pid[$pid]=${BASH_REMATCH[1]}
    fi
  done < <("$nvidia_smi" 2>/dev/null)

  tmp=$(mktemp "$cache_file.XXXXXX") || return
  {
    printf '%s %s %s\n' "$now" "$fan" "$memory"
    for pid in "${!memory_by_pid[@]}"; do
      printf '%s %s\n' "$pid" "${memory_by_pid[$pid]}"
    done
  } > "$tmp"
  mv -f -- "$tmp" "$cache_file"
}

if [[ ${1:-} == refresh ]]; then
  refresh_cache
  exit 0
fi

case ${1:-} in
  fan|system_vram|game_vram) ;;
  *)
    printf 'usage: %s {fan|system_vram|game_vram}\n' "$0" >&2
    exit 2
    ;;
esac

printf -v now '%(%s)T' -1
if [[ -r $cache_file.attempt ]]; then
  IFS= read -r attempted < "$cache_file.attempt"
fi
if [[ ! ${attempted:-} =~ ^[0-9]+$ ]] || ((now - attempted >= 2)); then
  # All descriptors must be detached from MangoHud's shell output pipe.
  "$0" refresh </dev/null >/dev/null 2>&1 &
fi

if [[ -r $cache_file ]]; then
  IFS=' ' read -r sampled fan memory < "$cache_file"
fi
if [[ ! ${sampled:-} =~ ^[0-9]+$ ]] || ((now - sampled > 10)); then
  fan=--
  memory=--
fi

case $1 in
  fan)
    if [[ $fan =~ ^[0-9]+$ ]]; then printf '%s%%\n' "$fan"; else printf '%s\n' '--'; fi
    ;;
  system_vram)
    if [[ $memory =~ ^[0-9]+$ ]]; then format_gib "$memory"; else printf '%s\n' '--'; fi
    ;;
  game_vram)
    result=--
    if [[ -r $cache_file && $sampled =~ ^[0-9]+$ ]] && ((now - sampled <= 10)); then
      declare -A memory_by_pid=()
      {
        IFS= read -r _
        while read -r pid mib; do
          if [[ $pid =~ ^[0-9]+$ && $mib =~ ^[0-9]+$ ]]; then
            memory_by_pid[$pid]=$mib
          fi
        done
      } < "$cache_file"

      pid=${MANGOHUD_GAME_PID:-$PPID}
      for ((depth = 0; depth < 16 && pid > 1; depth++)); do
        if [[ -n ${memory_by_pid[$pid]+present} ]]; then
          result=$(format_gib "${memory_by_pid[$pid]}")
          break
        fi
        [[ -r /proc/$pid/status ]] || break
        parent=
        while read -r key value _; do
          if [[ $key == PPid: ]]; then parent=$value; break; fi
        done < "/proc/$pid/status"
        [[ $parent =~ ^[0-9]+$ ]] || break
        pid=$parent
      done
    fi
    printf 'Game %s\n' "$result"
    ;;
esac
