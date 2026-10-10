#!/usr/bin/env bash

# MangoHud's exec rows read the same local hwmon values as wireviewctl top.
# Pin groups and imbalance use complete six-pin snapshots in RAM. A missed
# sensor read leaves the last valid snapshot available for the next refresh.
pin_cache_file=/run/user/$UID/mangohud-wireview-pins
# A custom hwmon root is used by local checks; keep its snapshot separate.
[[ -z ${WIREVIEW_HWMON_ROOT:-} ]] || pin_cache_file+=-test

find_device() {
  local hwmon name
  # Discover by name because hwmon numbers can change across boots.
  for hwmon in "${WIREVIEW_HWMON_ROOT:-/sys/class/hwmon}"/hwmon*; do
    [[ -r "$hwmon/name" ]] || continue
    IFS= read -r name < "$hwmon/name"
    if [[ $name == wireview ]]; then
      device=$hwmon
      return 0
    fi
  done
  return 1
}

read_value() {
  [[ -r "$device/$1" ]] || return 1
  value=
  IFS= read -r value < "$device/$1" 2>/dev/null || return 1
  [[ $value =~ ^[0-9]+$ ]]
}

refresh_pins() {
  local now uptime pin tmp
  local -a pin_values=()

  exec 9>"$pin_cache_file.lock" || return
  /nix/var/nix/profiles/system/sw/bin/flock -n 9 || return
  printf -v now '%(%s)T' -1
  printf '%s\n' "$now" > "$pin_cache_file.attempt"
  find_device || return
  for pin in 1 2 3 4 5 6; do
    read_value "curr${pin}_input" || return
    pin_values+=("$value")
  done
  IFS=' .' read -r uptime _ < /proc/uptime || return

  tmp=$(mktemp "$pin_cache_file.XXXXXX") || return
  printf '%s %s %s %s %s %s %s %s\n' "$now" "$uptime" "${pin_values[@]}" > "$tmp"
  mv -f -- "$tmp" "$pin_cache_file"
}

if [[ ${1:-} == refresh_pins ]]; then
  refresh_pins
  exit 0
fi

case ${1:-} in
  imbalance|pins_1_3|pins_4_6)
    printf -v now '%(%s)T' -1
    if [[ -r $pin_cache_file.attempt ]]; then
      IFS= read -r attempted < "$pin_cache_file.attempt"
    fi
    if [[ ! ${attempted:-} =~ ^[0-9]+$ ]] || ((now - attempted >= 1)); then
      "$0" refresh_pins </dev/null >/dev/null 2>&1 &
    fi
    if [[ -r $pin_cache_file ]]; then
      read -r sampled sample_uptime pin1 pin2 pin3 pin4 pin5 pin6 < "$pin_cache_file"
    fi
    if [[ ! ${sampled:-} =~ ^[0-9]+$ ]] || ((now - sampled > 10)); then
      printf 'unavailable\n'
      exit 0
    fi
    if [[ ! ${sample_uptime:-} =~ ^[0-9]+$ ]]; then
      printf 'unavailable\n'
      exit 0
    fi
    pin_values=("$pin1" "$pin2" "$pin3" "$pin4" "$pin5" "$pin6")
    for value in "${pin_values[@]}"; do
      if [[ ! $value =~ ^[0-9]+$ ]]; then printf 'unavailable\n'; exit 0; fi
    done

    if [[ $1 == imbalance ]]; then
      lowest=${pin_values[0]}
      highest=$lowest
      sum=0
      for value in "${pin_values[@]}"; do
        if ((value < lowest)); then lowest=$value; fi
        if ((value > highest)); then highest=$value; fi
        ((sum += value))
      done
      if ((sum == 0)); then printf 'unavailable\n'; exit 0; fi
      # Match the Noctalia widget: (highest - lowest) / mean current * 100.
      imbalance_tenths=$((((highest - lowest) * 6000 + sum / 2) / sum))
      printf 'Imbal %d.%d%%\n' "$((imbalance_tenths / 10))" "$((imbalance_tenths % 10))"
    else
      if [[ $1 == pins_1_3 ]]; then
        pin_values=("${pin_values[@]:0:3}")
      else
        pin_values=("${pin_values[@]:3:3}")
      fi
      pin_currents=()
      for value in "${pin_values[@]}"; do
        tenths=$(((value + 50) / 100))
        pin_currents+=("$((tenths / 10)).$((tenths % 10))")
      done
      printf '%s/%s/%sA\n' "${pin_currents[@]}"
    fi
    exit 0
    ;;
esac

if ! find_device; then
  printf 'unavailable\n'
  exit 0
fi

case ${1:-} in
  power)
    if ! read_value power1_input; then printf 'unavailable\n'; exit 0; fi
    printf '%dW\n' "$(((value + 500000) / 1000000))"
    ;;
  current)
    if ! read_value curr7_input; then printf 'unavailable\n'; exit 0; fi
    current_hundredths=$(((value + 5) / 10))
    printf '%d.%02d A\n' "$((current_hundredths / 100))" "$((current_hundredths % 100))"
    ;;
  temps)
    temps=()
    for channel in 1 2; do
      if read_value "temp${channel}_input" && ((value > 0)); then
        temps+=("$(((value + 500) / 1000))")
      else
        temps+=(--)
      fi
    done
    printf '%s/%s°C\n' "${temps[@]}"
    ;;
  external)
    temps=()
    for channel in 3 4; do
      if read_value "temp${channel}_input" && ((value > 0)); then
        temps+=("$(((value + 500) / 1000))")
      else
        temps+=(--)
      fi
    done
    printf 'Ext %s/%s°C\n' "${temps[@]}"
    ;;
  fan)
    if read_value pwm1; then
      fan="$(((value * 100 + 127) / 255))%"
    else
      fan=--
    fi
    printf 'Fan %s\n' "$fan"
    ;;
  faults)
    if read_value fault_status_raw; then
      if ((value == 0)); then
        faults=none
      else
        printf -v faults '0x%X' "$value"
      fi
    else
      faults=--
    fi
    printf 'Faults %s\n' "$faults"
    ;;
  *)
    printf 'usage: %s {power|current|imbalance|pins_1_3|pins_4_6|temps|external|fan|faults}\n' "$0" >&2
    exit 2
    ;;
esac
