# Guarded NixOS update workflow.
#
# `update` updates flake inputs, builds a candidate while watching free space,
# shows the closure diff, then activates that exact pre-built closure.
# `update --check` only prints the storage report.

_smart_update_format_bytes() {
  local bytes="${1:-0}"
  numfmt --to=si --suffix=B --format='%.1f' "$bytes" 2>/dev/null \
    || print -r -- "${bytes} B"
}

_smart_update_parse_size() {
  local value="${1%% *}"
  awk -v value="$value" 'BEGIN {
    if (!match(value, /^([0-9.]+)([A-Za-z]+)$/, parts)) {
      print 0
      exit
    }
    number = parts[1] + 0
    unit = parts[2]
    multiplier = 1
    if (unit == "kB" || unit == "KB") multiplier = 1000
    else if (unit == "MB") multiplier = 1000^2
    else if (unit == "GB") multiplier = 1000^3
    else if (unit == "TB") multiplier = 1000^4
    else if (unit == "KiB") multiplier = 1024
    else if (unit == "MiB") multiplier = 1024^2
    else if (unit == "GiB") multiplier = 1024^3
    else if (unit == "TiB") multiplier = 1024^4
    printf "%.0f\n", number * multiplier
  }'
}

_smart_update_free_bytes() {
  df --output=avail -B1 "$1" 2>/dev/null | awk 'NR == 2 { print $1 }'
}

_smart_update_old_files_size() {
  local target="$1" days="$2"
  [[ -d "$target" ]] || {
    print -r -- 0
    return
  }
  find "$target" -xdev -type f -mtime "+$days" -printf '%s\n' 2>/dev/null \
    | awk '{ total += $1 } END { printf "%.0f\n", total }'
}

_smart_update_nix_reclaimable() {
  local dead_paths
  dead_paths=$(timeout 8s nix-store --gc --print-dead 2>/dev/null) || {
    print -r -- 0
    return
  }
  [[ -n "$dead_paths" ]] || {
    print -r -- 0
    return
  }
  print -r -- "$dead_paths" \
    | xargs -r du -s -B1 -c -- 2>/dev/null \
    | awk '$2 == "total" { total += $1 } END { printf "%.0f\n", total }'
}

_smart_update_btrfs_min_bytes() {
  btrfs filesystem usage -b / 2>/dev/null | awk '
    /Free \(estimated\):/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "(min:") {
          value = $(i + 1)
          gsub(/[^0-9]/, "", value)
          print value
          exit
        }
      }
    }
  '
}

_smart_update_print_top() {
  local title="$1" target="$2" count="${3:-8}"
  local bytes item

  [[ -d "$target" ]] || return 0
  print
  print -r -- "$title"
  while IFS=$'\t' read -r bytes item; do
    printf '  %9s  %s\n' "$(_smart_update_format_bytes "$bytes")" "$item"
  done < <(
    du -a -x -B1 -d1 -- "$target" 2>/dev/null \
      | sort -rn \
      | awk -F '\t' -v target="$target" '$2 != target' \
      | head -n "$count"
  )
}

_smart_update_storage_bar() {
  local pct="$1" width="${2:-22}"
  local filled=$((pct * width / 100))
  local color="$_smart_green"
  (( pct >= 90 )) && color="$_smart_red"
  (( pct >= 75 && pct < 90 )) && color="$_smart_yellow"

  printf '['
  printf '%s' "$color"
  local i
  for ((i = 0; i < width; i++)); do
    if (( i < filled )); then
      printf '█'
    else
      printf '░'
    fi
  done
  printf '%s]' "$_smart_reset"
}

_smart_update_container_compact() {
  local engine="$1" label="$2"
  local output type size reclaimable reclaimable_bytes total_reclaimable=0

  if [[ "$engine" == docker ]]; then
    _smart_docker_reclaimable=0
  else
    _smart_podman_reclaimable=0
  fi

  printf '\n  %s%s%s\n' "$_smart_bold" "$label" "$_smart_reset"
  if ! command -v "$engine" >/dev/null; then
    printf '    %snot installed%s\n' "$_smart_dim" "$_smart_reset"
    return
  fi
  if ! timeout 3s "$engine" info >/dev/null 2>&1; then
    printf '    %sunavailable%s\n' "$_smart_dim" "$_smart_reset"
    return
  fi

  output=$(
    timeout 5s "$engine" system df \
      --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2>/dev/null
  )
  if [[ -z "$output" ]]; then
    printf '    %sno storage data%s\n' "$_smart_dim" "$_smart_reset"
    return
  fi

  while IFS=$'\t' read -r type size reclaimable; do
    reclaimable_bytes=$(_smart_update_parse_size "$reclaimable")
    (( total_reclaimable += reclaimable_bytes ))
    printf '    %-14s %9s  %s%s reclaimable%s\n' \
      "$type" "$size" "$_smart_dim" "$reclaimable" "$_smart_reset"
  done <<< "$output"

  if [[ "$engine" == docker ]]; then
    _smart_docker_reclaimable="$total_reclaimable"
  else
    _smart_podman_reclaimable="$total_reclaimable"
  fi
}

_smart_update_sum_paths() {
  local total=0 bytes target
  for target in "$@"; do
    [[ -e "$target" ]] || continue
    bytes=$(du -sx -B1 -- "$target" 2>/dev/null | awk '{ print $1 }')
    [[ "$bytes" == <-> ]] && (( total += bytes ))
  done
  print -r -- "$total"
}

_smart_update_storage_metric() {
  local label="$1" bytes="$2"
  (( bytes > 0 )) || return
  printf '    %-18s %9s\n' "$label" "$(_smart_update_format_bytes "$bytes")"
}

_smart_update_storage_compact() {
  local root_size root_used root_free root_pct
  local boot_size boot_used boot_free boot_pct
  local btrfs_usage btrfs_min btrfs_unallocated
  local nix_store_size generation_count journal_usage
  local root_color boot_color btrfs_color
  local persistent_home="/persist/home/$USER"
  local downloads_size npm_size cargo_size rust_toolchains_size bun_size python_size
  local go_size java_size maven_size pnpm_yarn_size dev_cache_size installed_dev_size
  local steam_root steam_size proton_prefix_size proton_runtime_size shader_size
  local old_downloads_30 old_downloads_90 nix_reclaimable ghfs_size
  local reclaimable_total update_state update_color suggestions=0
  local start_target=$((35 * 1024 * 1024 * 1024))
  local btrfs_start_floor=$((20 * 1024 * 1024 * 1024))
  local boot_floor=$((256 * 1024 * 1024))
  local -a proton_runtime_paths

  if [[ -t 1 ]] && command -v tput >/dev/null; then
    _smart_bold=$(tput bold 2>/dev/null)
    _smart_dim=$(tput dim 2>/dev/null)
    _smart_red=$(tput setaf 1 2>/dev/null)
    _smart_green=$(tput setaf 2 2>/dev/null)
    _smart_yellow=$(tput setaf 3 2>/dev/null)
    _smart_blue=$(tput setaf 4 2>/dev/null)
    _smart_cyan=$(tput setaf 6 2>/dev/null)
    _smart_reset=$(tput sgr0 2>/dev/null)
  else
    _smart_bold="" _smart_dim="" _smart_red="" _smart_green=""
    _smart_yellow="" _smart_blue="" _smart_cyan="" _smart_reset=""
  fi
  [[ -d "$persistent_home" ]] || persistent_home="$HOME"

  read -r root_size root_used root_free root_pct < <(
    df --output=size,used,avail,pcent -B1 / \
      | awk 'NR == 2 { gsub(/%/, "", $4); print $1, $2, $3, $4 }'
  )
  read -r boot_size boot_used boot_free boot_pct < <(
    df --output=size,used,avail,pcent -B1 /boot \
      | awk 'NR == 2 { gsub(/%/, "", $4); print $1, $2, $3, $4 }'
  )

  btrfs_usage=$(btrfs filesystem usage -b / 2>/dev/null)
  btrfs_min=$(awk '
    /Free \(estimated\):/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "(min:") {
          value = $(i + 1)
          gsub(/[^0-9]/, "", value)
          print value
          exit
        }
      }
    }
  ' <<< "$btrfs_usage")
  btrfs_unallocated=$(awk '/Device unallocated:/ { print $3; exit }' <<< "$btrfs_usage")
  [[ "$btrfs_min" == <-> ]] || btrfs_min="$root_free"
  [[ "$btrfs_unallocated" == <-> ]] || btrfs_unallocated=0
  nix_store_size=$(du -sx -B1 -- /nix/store 2>/dev/null | awk '{ print $1 }')
  generation_count=$(
    find /nix/var/nix/profiles -maxdepth 1 -type l -name 'system-*-link' \
      2>/dev/null | wc -l
  )
  journal_usage=$(journalctl --disk-usage --quiet 2>/dev/null)
  journal_usage=${journal_usage#*take up }
  journal_usage=${journal_usage% in the file system.*}
  journal_usage=$(sed -E 's/^([0-9.]+)([KMGT])$/\1 \2B/' <<< "$journal_usage")

  downloads_size=$(_smart_update_sum_paths "$persistent_home/Downloads")
  old_downloads_30=$(_smart_update_old_files_size "$persistent_home/Downloads" 30)
  old_downloads_90=$(_smart_update_old_files_size "$persistent_home/Downloads" 90)
  ghfs_size=$(_smart_update_sum_paths "$persistent_home/.cache/ghfs")
  npm_size=$(_smart_update_sum_paths "$persistent_home/.npm")
  cargo_size=$(_smart_update_sum_paths \
    "$persistent_home/.cargo/registry" \
    "$persistent_home/.cargo/git")
  rust_toolchains_size=$(_smart_update_sum_paths \
    "$persistent_home/.rustup/toolchains")
  bun_size=$(_smart_update_sum_paths "$persistent_home/.bun/install/cache")
  python_size=$(_smart_update_sum_paths \
    "$persistent_home/.cache/pip" \
    "$persistent_home/.cache/uv" \
    "$persistent_home/.cache/pypoetry")
  go_size=$(_smart_update_sum_paths \
    "$persistent_home/go/pkg/mod" \
    "$persistent_home/.cache/go-build")
  java_size=$(_smart_update_sum_paths \
    "$persistent_home/.gradle/caches")
  maven_size=$(_smart_update_sum_paths "$persistent_home/.m2/repository")
  pnpm_yarn_size=$(_smart_update_sum_paths \
    "$persistent_home/.local/share/pnpm/store" \
    "$persistent_home/.cache/yarn" \
    "$persistent_home/.yarn/berry/cache")
  dev_cache_size=$((npm_size + cargo_size + bun_size + python_size
    + go_size + java_size + pnpm_yarn_size))
  installed_dev_size=$((rust_toolchains_size + maven_size))

  steam_root="$persistent_home/.local/share/Steam"
  steam_size=$(_smart_update_sum_paths "$steam_root")
  proton_prefix_size=$(_smart_update_sum_paths "$steam_root/steamapps/compatdata")
  shader_size=$(_smart_update_sum_paths "$steam_root/steamapps/shadercache")
  proton_runtime_paths=(
    "$steam_root/steamapps/common"/Proton*(N)
    "$steam_root/compatibilitytools.d"/*(N)
  )
  proton_runtime_size=$(_smart_update_sum_paths "${proton_runtime_paths[@]}")
  nix_reclaimable=$(_smart_update_nix_reclaimable)

  root_color="$_smart_green"
  (( root_pct >= 90 )) && root_color="$_smart_red"
  (( root_pct >= 75 && root_pct < 90 )) && root_color="$_smart_yellow"
  boot_color="$_smart_green"
  (( boot_pct >= 90 )) && boot_color="$_smart_red"
  (( boot_pct >= 75 && boot_pct < 90 )) && boot_color="$_smart_yellow"
  btrfs_color="$_smart_green"
  (( btrfs_min < 12 * 1024 * 1024 * 1024 )) && btrfs_color="$_smart_yellow"
  (( btrfs_min < 8 * 1024 * 1024 * 1024 )) && btrfs_color="$_smart_red"
  if (( root_free < start_target
        || btrfs_min < btrfs_start_floor
        || boot_free < boot_floor )); then
    update_state="BLOCKED"
    update_color="$_smart_red"
  elif (( root_free < start_target + 10 * 1000 * 1000 * 1000 )); then
    update_state="TIGHT"
    update_color="$_smart_yellow"
  else
    update_state="SAFE"
    update_color="$_smart_green"
  fi

  printf '\n%s%sStorage%s\n\n' "$_smart_bold" "$_smart_blue" "$_smart_reset"
  printf '  %s%-6s%s ' "$_smart_bold" "/" "$_smart_reset"
  _smart_update_storage_bar "$root_pct"
  printf '  %3d%%  %s%s free%s\n' \
    "$root_pct" "$root_color" "$(_smart_update_format_bytes "$root_free")" "$_smart_reset"

  printf '  %s%-6s%s ' "$_smart_bold" "/boot" "$_smart_reset"
  _smart_update_storage_bar "$boot_pct"
  printf '  %3d%%  %s%s free%s\n' \
    "$boot_pct" "$boot_color" "$(_smart_update_format_bytes "$boot_free")" "$_smart_reset"

  printf '\n  %sBtrfs safe%s   %s%s%s\n' \
    "$_smart_cyan" "$_smart_reset" "$btrfs_color" \
    "$(_smart_update_format_bytes "$btrfs_min")" "$_smart_reset"
  printf '  %sUnallocated%s  %s\n' \
    "$_smart_cyan" "$_smart_reset" "$(_smart_update_format_bytes "$btrfs_unallocated")"
  printf '  %sNix store%s    %s %s(logical)%s\n' \
    "$_smart_cyan" "$_smart_reset" "$(_smart_update_format_bytes "$nix_store_size")" \
    "$_smart_dim" "$_smart_reset"
  printf '  %sLogs%s         %s\n' "$_smart_cyan" "$_smart_reset" "$journal_usage"
  printf '  %sRollbacks%s    %s\n' "$_smart_cyan" "$_smart_reset" "$generation_count"

  printf '\n  %s%sUpdate safety%s\n' "$_smart_bold" "$_smart_cyan" "$_smart_reset"
  printf '    %s%s%s — %s available / %s required\n' \
    "$update_color" "$update_state" "$_smart_reset" \
    "$(_smart_update_format_bytes "$root_free")" \
    "$(_smart_update_format_bytes "$start_target")"

  printf '\n  %s%sUser data%s\n' "$_smart_bold" "$_smart_cyan" "$_smart_reset"
  _smart_update_storage_metric Downloads "$downloads_size"
  printf '    %-18s %9s\n' "Older than 30d" \
    "$(_smart_update_format_bytes "$old_downloads_30")"
  printf '    %-18s %9s\n' "Older than 90d" \
    "$(_smart_update_format_bytes "$old_downloads_90")"

  if (( dev_cache_size > 0 )); then
    printf '\n  %s%sRegenerable developer caches%s\n' \
      "$_smart_bold" "$_smart_cyan" "$_smart_reset"
    _smart_update_storage_metric npm "$npm_size"
    _smart_update_storage_metric "Cargo cache" "$cargo_size"
    _smart_update_storage_metric Bun "$bun_size"
    _smart_update_storage_metric Python "$python_size"
    _smart_update_storage_metric Go "$go_size"
    _smart_update_storage_metric Java "$java_size"
    _smart_update_storage_metric pnpm/Yarn "$pnpm_yarn_size"
  fi

  if (( installed_dev_size > 0 )); then
    printf '\n  %s%sInstalled developer data%s\n' \
      "$_smart_bold" "$_smart_cyan" "$_smart_reset"
    _smart_update_storage_metric "Rust toolchains" "$rust_toolchains_size"
    _smart_update_storage_metric "Maven repository" "$maven_size"
  fi

  if (( steam_size > 0 )); then
    printf '\n  %s%sSteam%s\n' "$_smart_bold" "$_smart_cyan" "$_smart_reset"
    _smart_update_storage_metric "Total" "$steam_size"
    _smart_update_storage_metric "Proton prefixes" "$proton_prefix_size"
    _smart_update_storage_metric "Proton runtimes" "$proton_runtime_size"
    _smart_update_storage_metric "Shader cache" "$shader_size"
  fi

  _smart_update_container_compact docker Docker
  _smart_update_container_compact podman Podman

  reclaimable_total=$((nix_reclaimable + _smart_docker_reclaimable
    + _smart_podman_reclaimable + dev_cache_size + old_downloads_90))
  printf '\n  %s%sReclaimable candidates (estimated)%s\n' \
    "$_smart_bold" "$_smart_cyan" "$_smart_reset"
  _smart_update_storage_metric "Nix dead paths" "$nix_reclaimable"
  _smart_update_storage_metric "Docker unused" "$_smart_docker_reclaimable"
  _smart_update_storage_metric "Podman unused" "$_smart_podman_reclaimable"
  _smart_update_storage_metric "Developer caches" "$dev_cache_size"
  _smart_update_storage_metric "Downloads >90d" "$old_downloads_90"
  if (( reclaimable_total > 0 )); then
    printf '    %s%-18s %9s%s\n' "$_smart_bold" "Total estimate" \
      "$(_smart_update_format_bytes "$reclaimable_total")" "$_smart_reset"
  else
    printf '    %sNo obvious reclaimable data found%s\n' "$_smart_dim" "$_smart_reset"
  fi

  printf '\n  %s%sSuggestions%s\n' "$_smart_bold" "$_smart_cyan" "$_smart_reset"
  if [[ "$update_state" == BLOCKED ]]; then
    printf '    %s• Update is blocked until more space is available%s\n' \
      "$_smart_red" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( nix_reclaimable > 1000 * 1000 * 1000 )); then
    printf '    • Reclaim %s of dead Nix paths: %sos clean nix%s\n' \
      "$(_smart_update_format_bytes "$nix_reclaimable")" \
      "$_smart_bold" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( _smart_docker_reclaimable > 1000 * 1000 * 1000 )); then
    printf '    • Docker can reclaim %s: %sos clean docker%s\n' \
      "$(_smart_update_format_bytes "$_smart_docker_reclaimable")" \
      "$_smart_bold" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( _smart_podman_reclaimable > 1000 * 1000 * 1000 )); then
    printf '    • Podman can reclaim %s: %sos clean podman%s\n' \
      "$(_smart_update_format_bytes "$_smart_podman_reclaimable")" \
      "$_smart_bold" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( dev_cache_size > 1000 * 1000 * 1000 )); then
    printf '    • Developer caches total %s: %sos clean dev-caches%s\n' \
      "$(_smart_update_format_bytes "$dev_cache_size")" \
      "$_smart_bold" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( old_downloads_90 > 500 * 1000 * 1000 )); then
    printf '    • Downloads older than 90 days use %s: %sos clean downloads%s\n' \
      "$(_smart_update_format_bytes "$old_downloads_90")" \
      "$_smart_bold" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( ghfs_size > 2 * 1000 * 1000 * 1000 )); then
    printf '    • ghfs cache is %s; inspect it with %sos storage%s\n' \
      "$(_smart_update_format_bytes "$ghfs_size")" \
      "$_smart_bold" "$_smart_reset"
    (( suggestions++ ))
  fi
  if (( suggestions == 0 )); then
    printf '    %sNo urgent cleanup suggested%s\n' "$_smart_dim" "$_smart_reset"
  fi

  printf '\n  %sFull breakdown:%s os storage\n\n' "$_smart_dim" "$_smart_reset"
}

update-storage() {
  emulate -L zsh
  setopt PIPE_FAIL

  if [[ "$1" == "--compact" ]]; then
    _smart_update_storage_compact
    return
  fi

  local root_free root_size root_used root_pct
  local boot_free boot_size boot_used boot_pct
  local btrfs_free btrfs_min btrfs_unallocated btrfs_usage
  local generation_count journal_usage nix_store_size
  local persistent_home="/persist/home/$USER"

  root_free=$(_smart_update_free_bytes /) || {
    print -u2 -- "update: cannot read free space for /"
    return 1
  }
  read -r root_size root_used root_pct < <(
    df --output=size,used,pcent -B1 / | awk 'NR == 2 { print $1, $2, $3 }'
  )
  read -r boot_size boot_used boot_pct < <(
    df --output=size,used,pcent -B1 /boot | awk 'NR == 2 { print $1, $2, $3 }'
  )
  boot_free=$(_smart_update_free_bytes /boot)

  printf '\nStorage preflight\n'
  printf '  %-12s %9s free / %9s  (%s used)\n' \
    "/" "$(_smart_update_format_bytes "$root_free")" \
    "$(_smart_update_format_bytes "$root_size")" "$root_pct"
  printf '  %-12s %9s free / %9s  (%s used)\n' \
    "/boot" "$(_smart_update_format_bytes "$boot_free")" \
    "$(_smart_update_format_bytes "$boot_size")" "$boot_pct"

  if btrfs_usage=$(btrfs filesystem usage -b / 2>/dev/null); then
    btrfs_free=$(awk '/Free \(estimated\):/ { print $3; exit }' <<< "$btrfs_usage")
    btrfs_min=$(awk '
      /Free \(estimated\):/ {
        for (i = 1; i <= NF; i++) {
          if ($i == "(min:") {
            value = $(i + 1)
            gsub(/[^0-9]/, "", value)
            print value
            exit
          }
        }
      }
    ' <<< "$btrfs_usage")
    btrfs_unallocated=$(awk '/Device unallocated:/ { print $3; exit }' <<< "$btrfs_usage")
    if [[ "$btrfs_free" == <-> && "$btrfs_unallocated" == <-> ]]; then
      printf '  %-12s %9s estimated free, %s unallocated\n' \
        "Btrfs" "$(_smart_update_format_bytes "$btrfs_free")" \
        "$(_smart_update_format_bytes "$btrfs_unallocated")"
      if [[ "$btrfs_min" == <-> ]]; then
        printf '  %-12s %9s conservative minimum free\n' \
          "" "$(_smart_update_format_bytes "$btrfs_min")"
      fi
    fi
  fi

  generation_count=$(
    find /nix/var/nix/profiles -maxdepth 1 -type l -name 'system-*-link' \
      2>/dev/null | wc -l
  )
  printf '  %-12s %9s system generations retained\n' "Rollbacks" "$generation_count"

  if journal_usage=$(journalctl --disk-usage --quiet 2>/dev/null); then
    printf '  %-12s %s\n' "Journal" "$journal_usage"
  fi
  nix_store_size=$(du -sx -B1 -- /nix/store 2>/dev/null | awk '{ print $1 }')
  if [[ "$nix_store_size" == <-> ]]; then
    printf '  %-12s %9s logical size\n' \
      "Nix store" "$(_smart_update_format_bytes "$nix_store_size")"
  fi

  # These are logical sizes. Btrfs compression and shared extents mean they do
  # not add up exactly to the physical usage reported above.
  _smart_update_print_top "Largest persistent home entries (logical size)" \
    "$persistent_home" 10
  _smart_update_print_top "Largest Downloads entries" \
    "$persistent_home/Downloads" 8
  _smart_update_print_top "Largest cache entries" \
    "$persistent_home/.cache" 8
  _smart_update_print_top "Largest local application-data entries" \
    "$persistent_home/.local/share" 8

  if sudo -n true 2>/dev/null; then
    local system_usage log_usage
    system_usage=$(sudo -n du -x -B1 -d1 -- /persist/var/lib 2>/dev/null)
    if [[ -n "$system_usage" ]]; then
      print
      print -r -- "Largest persistent system-state entries (logical size)"
      while IFS=$'\t' read -r bytes item; do
        printf '  %9s  %s\n' "$(_smart_update_format_bytes "$bytes")" "$item"
      done < <(
        print -r -- "$system_usage" \
          | sort -rn \
          | awk -F '\t' '$2 != "/persist/var/lib"' \
          | head -n 8
      )
    fi

    log_usage=$(sudo -n du -a -x -B1 -d2 -- /persist/var/log 2>/dev/null)
    if [[ -n "$log_usage" ]]; then
      print
      print -r -- "Largest persistent log entries (logical size)"
      while IFS=$'\t' read -r bytes item; do
        printf '  %9s  %s\n' "$(_smart_update_format_bytes "$bytes")" "$item"
      done < <(
        print -r -- "$log_usage" \
          | sort -rn \
          | awk -F '\t' '$2 != "/persist/var/log"' \
          | head -n 8
      )
    fi
  else
    print
    print -r -- "  System-state detail: authenticate with sudo, then run update --check"
  fi

  if command -v docker >/dev/null && timeout 3s docker info >/dev/null 2>&1; then
    print
    print -r -- "Docker usage"
    timeout 5s docker system df 2>/dev/null | sed 's/^/  /'
  elif command -v docker >/dev/null; then
    print
    print -r -- "Docker usage"
    print -r -- "  Daemon unavailable"
  fi
  if command -v podman >/dev/null && timeout 3s podman info >/dev/null 2>&1; then
    print
    print -r -- "Podman usage"
    timeout 5s podman system df 2>/dev/null | sed 's/^/  /'
  elif command -v podman >/dev/null; then
    print
    print -r -- "Podman usage"
    print -r -- "  Storage unavailable"
  fi
  print
}

_smart_storage_clean_confirm() {
  local prompt="$1" answer
  if { : < /dev/tty } 2>/dev/null; then
    printf '%s [y/N] ' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty
  elif [[ -t 0 && -t 1 ]]; then
    printf '%s [y/N] ' "$prompt"
    IFS= read -r answer
  else
    print -u2 -- "os clean: refusing destructive cleanup without an interactive terminal"
    return 1
  fi
  [[ "$answer" == [yY] ]]
}

_smart_storage_clean_result() {
  local before="$1" after delta
  after=$(_smart_update_free_bytes /)
  delta=$((after - before))
  if (( delta >= 0 )); then
    printf '\nRoot free-space change: +%s\n' "$(_smart_update_format_bytes "$delta")"
  else
    printf '\nRoot free-space change: -%s\n' "$(_smart_update_format_bytes "$((-delta))")"
  fi
}

storage-clean() {
  emulate -L zsh
  setopt PIPE_FAIL

  local target="$1"
  local persistent_home="/persist/home/$USER"
  local before size count item bytes
  local -a cache_paths
  [[ -d "$persistent_home" ]] || persistent_home="$HOME"

  if [[ -z "$target" ]]; then
    print -r -- "Usage: os clean <target>"
    print
    print -r -- "Targets:"
    print -r -- "  nix          unreachable Nix store paths; keeps system generations"
    print -r -- "  docker       stopped containers, unused images/networks, build cache"
    print -r -- "  podman       unused Podman objects; volumes are not included"
    print -r -- "  dev-caches   regenerable npm/Cargo/Bun/Python/Go/Gradle/pnpm caches"
    print -r -- "  downloads    permanently delete files older than 90 days"
    print
    print -r -- "Every target previews its scope and asks before deletion."
    return 0
  fi

  before=$(_smart_update_free_bytes /)
  case "$target" in
    nix)
      size=$(_smart_update_nix_reclaimable)
      printf '\nNix cleanup preview\n'
      printf '  Unreachable store paths: approximately %s logical\n' \
        "$(_smart_update_format_bytes "$size")"
      print -r -- "  System profiles and rollback generations remain GC roots."
      (( size > 0 )) || {
        print -r -- "Nothing to clean."
        return 0
      }
      _smart_storage_clean_confirm "Run Nix garbage collection?" || return 0
      sudo nix-store --gc || return
      ;;

    docker)
      command -v docker >/dev/null || {
        print -u2 -- "os clean: Docker is not installed"
        return 1
      }
      timeout 3s docker info >/dev/null 2>&1 || {
        print -u2 -- "os clean: Docker daemon is unavailable"
        return 1
      }
      print
      print -r -- "Docker cleanup preview"
      timeout 5s docker system df || return
      print
      print -r -- "Volumes are intentionally excluded."
      _smart_storage_clean_confirm \
        "Prune stopped containers, unused images/networks, and build cache?" || return 0
      docker system prune -a -f || return
      ;;

    podman)
      command -v podman >/dev/null || {
        print -u2 -- "os clean: Podman is not installed"
        return 1
      }
      timeout 3s podman info >/dev/null 2>&1 || {
        print -u2 -- "os clean: Podman storage is unavailable"
        return 1
      }
      print
      print -r -- "Podman cleanup preview"
      timeout 5s podman system df || return
      print
      print -r -- "Volumes are intentionally excluded."
      _smart_storage_clean_confirm "Prune unused Podman objects?" || return 0
      podman system prune -a -f || return
      ;;

    dev-caches)
      cache_paths=(
        "$persistent_home/.npm"
        "$persistent_home/.cargo/registry"
        "$persistent_home/.cargo/git"
        "$persistent_home/.bun/install/cache"
        "$persistent_home/.cache/pip"
        "$persistent_home/.cache/uv"
        "$persistent_home/.cache/pypoetry"
        "$persistent_home/go/pkg/mod"
        "$persistent_home/.cache/go-build"
        "$persistent_home/.gradle/caches"
        "$persistent_home/.local/share/pnpm/store"
        "$persistent_home/.cache/yarn"
        "$persistent_home/.yarn/berry/cache"
      )
      print
      print -r -- "Developer-cache cleanup preview"
      size=0
      for item in "${cache_paths[@]}"; do
        [[ -d "$item" && ! -L "$item" ]] || continue
        bytes=$(_smart_update_sum_paths "$item")
        (( bytes > 0 )) || continue
        (( size += bytes ))
        printf '  %9s  %s\n' "$(_smart_update_format_bytes "$bytes")" "$item"
      done
      printf '  %9s  %s\n' "$(_smart_update_format_bytes "$size")" "TOTAL"
      print -r -- "Rust toolchains, npm globals, Maven data, and project files are excluded."
      (( size > 0 )) || {
        print -r -- "Nothing to clean."
        return 0
      }
      _smart_storage_clean_confirm "Delete these regenerable cache contents?" || return 0
      for item in "${cache_paths[@]}"; do
        [[ -d "$item" && ! -L "$item" && "$item" == "$persistent_home/"* ]] || continue
        find "$item" -mindepth 1 -delete || return
      done
      ;;

    downloads)
      local downloads="$persistent_home/Downloads"
      [[ -d "$downloads" && ! -L "$downloads" ]] || {
        print -u2 -- "os clean: Downloads directory is unavailable or is a symlink"
        return 1
      }
      size=$(_smart_update_old_files_size "$downloads" 90)
      count=$(find "$downloads" -xdev -type f -mtime +90 -printf '.' 2>/dev/null \
        | wc -c)
      print
      print -r -- "Old-Downloads cleanup preview"
      printf '  %s file(s), %s total, older than 90 days\n\n' \
        "$count" "$(_smart_update_format_bytes "$size")"
      find "$downloads" -xdev -type f -mtime +90 \
        -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null \
        | sort -rn \
        | head -n 15 \
        | while IFS=$'\t' read -r bytes item_date item; do
            printf '  %9s  %s  %s\n' \
              "$(_smart_update_format_bytes "$bytes")" "$item_date" "$item"
          done
      (( count > 15 )) && printf '  ... and %d more\n' "$((count - 15))"
      (( count > 0 )) || {
        print -r -- "Nothing to clean."
        return 0
      }
      print
      _smart_storage_clean_confirm \
        "Permanently delete every Downloads file older than 90 days?" || return 0
      find "$downloads" -xdev -type f -mtime +90 -delete || return
      ;;

    *)
      print -u2 -- "os clean: unknown target '$target'"
      print -u2 -- "Valid targets: nix, docker, podman, dev-caches, downloads"
      return 2
      ;;
  esac

  _smart_storage_clean_result "$before"
}

_smart_update_cleanup() {
  local original_status="$1"
  local current_hash

  if [[ "$build_pid" == <-> ]] && kill -0 "$build_pid" 2>/dev/null; then
    kill -TERM "$build_pid" 2>/dev/null
    wait "$build_pid" 2>/dev/null
  fi

  if (( restore_lock )) && [[ -f "$lock_backup" ]]; then
    current_hash=$(sha256sum "$lock_file" 2>/dev/null | awk '{ print $1 }')
    if [[ -z "$lock_hash_after" || "$current_hash" == "$lock_hash_after" ]]; then
      command cp -f -- "$lock_backup" "$lock_file"
      print -u2 -- "update: restored the pre-update flake.lock after failure"
    else
      print -u2 -- "update: flake.lock changed concurrently; refusing to overwrite it"
    fi
    [[ -n "$candidate" ]] && command rm -f -- "$candidate"
  fi

  [[ -n "$lock_backup" ]] && command rm -f -- "$lock_backup"
  [[ -n "$run_lock" ]] && command rmdir -- "$run_lock" 2>/dev/null
  return "$original_status"
}

update() {
  emulate -L zsh
  setopt LOCAL_TRAPS PIPE_FAIL NO_NOTIFY

  local flake="$HOME/system-conf"
  local attr="$flake#nixosConfigurations.default.config.system.build.toplevel"
  local lock_file="$flake/flake.lock"
  local candidate="/tmp/nixos-update-${UID}"
  local candidate_path
  local lock_backup="" lock_hash_after="" run_lock=""
  local restore_lock=0 update_inputs=1 assume_yes=0 check_only=0
  local start_target=$((35 * 1024 * 1024 * 1024))
  local gc_trigger=$((25 * 1024 * 1024 * 1024))
  local emergency_floor=$((20 * 1024 * 1024 * 1024))
  local btrfs_start_floor=$((20 * 1024 * 1024 * 1024))
  local btrfs_emergency_floor=$((8 * 1024 * 1024 * 1024))
  local btrfs_activation_floor=$((12 * 1024 * 1024 * 1024))
  local boot_floor=$((256 * 1024 * 1024))
  local root_free btrfs_min boot_free answer build_pid="" build_status dirty_count

  while (( $# )); do
    case "$1" in
      --check)
        check_only=1
        ;;
      --no-input-update)
        update_inputs=0
        ;;
      --yes|-y)
        assume_yes=1
        ;;
      --help|-h)
        print -r -- "Usage: update [--check] [--no-input-update] [--yes]"
        print -r -- "  --check            storage diagnosis only"
        print -r -- "  --no-input-update  build the current lock file"
        print -r -- "  --yes, -y          activate after a successful guarded build"
        return 0
        ;;
      *)
        print -u2 -- "update: unknown option: $1"
        print -u2 -- "Try: update --help"
        return 2
        ;;
    esac
    shift
  done

  update-storage || return
  (( check_only )) && return 0

  [[ -d "$flake" && -f "$flake/flake.nix" && -f "$lock_file" ]] || {
    print -u2 -- "update: expected a flake with flake.lock at $flake"
    return 1
  }

  dirty_count=$(git -C "$flake" status --porcelain=v1 2>/dev/null | wc -l)
  if (( dirty_count > 0 )); then
    print -r -- "Working tree: $dirty_count uncommitted path(s); the candidate will include them."
  fi

  run_lock="${XDG_RUNTIME_DIR:-/tmp}/nixos-smart-update-${UID}.lock"
  if ! command mkdir -- "$run_lock" 2>/dev/null; then
    print -u2 -- "update: another update appears to be running ($run_lock)"
    return 1
  fi

  lock_backup=$(mktemp "/tmp/nixos-update-lock-${UID}.XXXXXX") || {
    command rmdir -- "$run_lock"
    return 1
  }
  command cp -- "$lock_file" "$lock_backup" || {
    command rm -f -- "$lock_backup"
    command rmdir -- "$run_lock"
    return 1
  }

  trap '_smart_update_cleanup $?' EXIT
  trap 'return 130' INT
  trap 'return 143' TERM HUP

  root_free=$(_smart_update_free_bytes /)
  btrfs_min=$(_smart_update_btrfs_min_bytes)
  [[ "$btrfs_min" == <-> ]] || btrfs_min="$root_free"
  boot_free=$(_smart_update_free_bytes /boot)

  if (( boot_free < boot_floor )); then
    print -u2 -- "update: refusing to continue: /boot has only $(_smart_update_format_bytes "$boot_free") free"
    print -u2 -- "Required safety floor: $(_smart_update_format_bytes "$boot_floor")"
    print -u2 -- "The configured Limine generation limit will prevent this after it is activated."
    return 1
  fi

  if (( root_free < start_target || btrfs_min < btrfs_start_floor )); then
    print -u2 -- "update: root does not meet the safe Btrfs start margins"
    print -u2 -- "  df free: $(_smart_update_format_bytes "$root_free") (need $(_smart_update_format_bytes "$start_target"))"
    print -u2 -- "  conservative Btrfs free: $(_smart_update_format_bytes "$btrfs_min") (need $(_smart_update_format_bytes "$btrfs_start_floor"))"
    if [[ -t 0 && -t 1 ]]; then
      printf 'Run safe Nix GC (keeps all system generations)? [Y/n] '
      IFS= read -r answer
      if [[ -z "$answer" || "$answer" == [yY] ]]; then
        sudo nix-store --gc || return
        root_free=$(_smart_update_free_bytes /)
        btrfs_min=$(_smart_update_btrfs_min_bytes)
        [[ "$btrfs_min" == <-> ]] || btrfs_min="$root_free"
      fi
    fi
    if (( root_free < start_target || btrfs_min < btrfs_start_floor )); then
      print -u2 -- "update: safe start margins are still not met; refusing to build"
      print -u2 -- "Inspect the report above. No generations or container data were deleted."
      return 1
    fi
  fi

  if (( update_inputs )); then
    print -r -- "Updating flake inputs..."
    restore_lock=1
    (
      builtin cd -- "$flake" &&
        nix flake update
    ) || return
    lock_hash_after=$(sha256sum "$lock_file" | awk '{ print $1 }') || return
  fi

  print
  print -r -- "Evaluating the build plan..."
  nix build "$attr" --dry-run \
    --option min-free "$gc_trigger" \
    --option max-free "$start_target" || return

  command rm -f -- "$candidate"
  print
  print -r -- "Building with live df and conservative Btrfs safety floors..."
  nix build "$attr" \
    --out-link "$candidate" \
    --print-build-logs \
    --option min-free "$gc_trigger" \
    --option max-free "$start_target" &
  build_pid=$!

  build_status=0
  while kill -0 "$build_pid" 2>/dev/null; do
    root_free=$(_smart_update_free_bytes /)
    btrfs_min=$(_smart_update_btrfs_min_bytes)
    [[ "$btrfs_min" == <-> ]] || btrfs_min="$root_free"
    if (( root_free < emergency_floor || btrfs_min < btrfs_emergency_floor )); then
      print -u2 -- "update: emergency floor reached; stopping the build"
      print -u2 -- "  df free: $(_smart_update_format_bytes "$root_free")"
      print -u2 -- "  conservative Btrfs free: $(_smart_update_format_bytes "$btrfs_min")"
      kill -TERM "$build_pid" 2>/dev/null
      wait "$build_pid" 2>/dev/null
      build_status=75
      break
    fi
    sleep 2
  done

  if (( build_status == 0 )); then
    wait "$build_pid"
    build_status=$?
  fi
  (( build_status == 0 )) || {
    command rm -f -- "$candidate"
    if (( root_free < gc_trigger )); then
      print -u2 -- "update: reclaiming unreachable build paths while preserving generations"
      sudo nix-store --gc
    fi
    return "$build_status"
  }

  candidate_path=$(readlink -f -- "$candidate") || return
  root_free=$(_smart_update_free_bytes /)
  btrfs_min=$(_smart_update_btrfs_min_bytes)
  [[ "$btrfs_min" == <-> ]] || btrfs_min="$root_free"
  boot_free=$(_smart_update_free_bytes /boot)
  if (( root_free < gc_trigger
        || btrfs_min < btrfs_activation_floor
        || boot_free < boot_floor )); then
    print -u2 -- "update: candidate built, but activation safety margins are not met"
    print -u2 -- "  df free: $(_smart_update_format_bytes "$root_free")"
    print -u2 -- "  conservative Btrfs free: $(_smart_update_format_bytes "$btrfs_min")"
    print -u2 -- "  /boot free: $(_smart_update_format_bytes "$boot_free")"
    command rm -f -- "$candidate"
    sudo nix-store --gc
    return 75
  fi

  print
  if command -v nvd >/dev/null; then
    print -r -- "System closure diff"
    nvd diff /run/current-system "$candidate_path" || true
  fi
  printf '\nCandidate: %s\n' "$candidate_path"
  printf 'Free after build: %s\n' "$(_smart_update_format_bytes "$root_free")"

  if (( ! assume_yes )); then
    if [[ ! -t 0 || ! -t 1 ]]; then
      print -u2 -- "update: non-interactive shell; candidate was built but not activated"
      print -u2 -- "Run update --yes to build and activate."
      restore_lock=0
      return 0
    fi
    printf 'Activate this exact pre-built system now? [y/N] '
    IFS= read -r answer
    if [[ "$answer" != [yY] ]]; then
      print -r -- "Not activated. Candidate retained at $candidate"
      restore_lock=0
      return 0
    fi
  fi

  # From this point onward the lock file describes the closure being activated;
  # do not roll it back even if activation itself reports an error.
  restore_lock=0
  print -r -- "Activating the already-built closure..."
  if ! sudo nixos-rebuild switch --store-path "$candidate_path"; then
    print -u2 -- "update: activation failed; candidate retained at $candidate"
    return 1
  fi

  command rm -f -- "$candidate"
  root_free=$(_smart_update_free_bytes /)
  print
  print -r -- "Update complete. Root free: $(_smart_update_format_bytes "$root_free")"
}
