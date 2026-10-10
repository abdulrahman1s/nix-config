# Sourced by MangoHud's persistent /bin/sh so these readings avoid a process
# launch. MangoHud only waits 50 ms for each exec result.
mangohud_fast_loaded=1

hud_find_hwmon() {
  hud_device=
  for hud_candidate in /sys/class/hwmon/hwmon*; do
    [ -r "$hud_candidate/name" ] || continue
    IFS= read -r hud_name < "$hud_candidate/name" || continue
    [ "$hud_name" = "$1" ] || continue
    hud_device=$hud_candidate
    return 0
  done
  return 1
}

hud_read_digits() {
  [ -r "$1" ] || return 1
  IFS= read -r hud_value < "$1" || return 1
  case $hud_value in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

hud_cpu_fan() {
  if hud_find_hwmon nct6798 && hud_read_digits "$hud_device/pwm3" && [ "$hud_value" -le 255 ]; then
    printf '%s%%\n' "$(((hud_value * 100 + 127) / 255))"
  else
    printf '%s\n' '--'
  fi
}

hud_wireview_current() {
  if hud_find_hwmon wireview && hud_read_digits "$hud_device/curr7_input"; then
    hud_hundredths=$(((hud_value + 5) / 10))
    printf '%d.%02d A\n' "$((hud_hundredths / 100))" "$((hud_hundredths % 100))"
  else
    printf 'unavailable\n'
  fi
}

hud_wireview_imbalance() {
  if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -r "$XDG_RUNTIME_DIR/mangohud-wireview-pins" ]; then
    printf 'unavailable\n'
    return
  fi
  read -r hud_sampled hud_sample_uptime hud_pin1 hud_pin2 hud_pin3 hud_pin4 hud_pin5 hud_pin6 < "$XDG_RUNTIME_DIR/mangohud-wireview-pins"
  IFS=' .' read -r hud_uptime _ < /proc/uptime
  for hud_value in "$hud_sampled" "$hud_sample_uptime" "$hud_uptime" "$hud_pin1" "$hud_pin2" "$hud_pin3" "$hud_pin4" "$hud_pin5" "$hud_pin6"; do
    case $hud_value in
      ''|*[!0-9]*) printf 'unavailable\n'; return ;;
    esac
  done
  if [ "$((hud_uptime - hud_sample_uptime))" -gt 10 ]; then
    printf 'unavailable\n'
    return
  fi
  hud_lowest=$hud_pin1
  hud_highest=$hud_pin1
  hud_sum=0
  for hud_value in "$hud_pin1" "$hud_pin2" "$hud_pin3" "$hud_pin4" "$hud_pin5" "$hud_pin6"; do
    [ "$hud_value" -ge "$hud_lowest" ] || hud_lowest=$hud_value
    [ "$hud_value" -le "$hud_highest" ] || hud_highest=$hud_value
    hud_sum=$((hud_sum + hud_value))
  done
  if [ "$hud_sum" -eq 0 ]; then
    printf 'unavailable\n'
    return
  fi
  hud_tenths=$((((hud_highest - hud_lowest) * 6000 + hud_sum / 2) / hud_sum))
  printf 'Imbal %d.%d%%\n' "$((hud_tenths / 10))" "$((hud_tenths % 10))"
}
