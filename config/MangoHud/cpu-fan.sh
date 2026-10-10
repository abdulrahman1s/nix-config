#!/bin/sh

# Identify the board sensor by name; its hwmon number changes across boots.
for hwmon in /sys/class/hwmon/hwmon*; do
  [ -r "$hwmon/name" ] || continue
  IFS= read -r name < "$hwmon/name"
  [ "$name" = nct6798 ] || continue

  if [ -r "$hwmon/pwm3" ] && IFS= read -r duty < "$hwmon/pwm3"; then
    case $duty in
      ''|*[!0-9]*) ;;
      *)
        if [ "$duty" -le 255 ]; then
          printf '%s%%\n' "$(((duty * 100 + 127) / 255))"
          exit 0
        fi
        ;;
    esac
  fi
  printf '%s\n' '--'
  exit 0
done

printf '%s\n' '--'
