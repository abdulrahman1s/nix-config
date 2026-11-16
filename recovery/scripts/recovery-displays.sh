set -Eeuo pipefail

# labwc has no output settings of its own. Run each monitor at its native
# resolution with the highest refresh rate it offers there, and pick a scale
# from that resolution, so nothing depends on monitor names.
#
# wlr-randr --mode matches the refresh rate to the millihertz; its JSON output
# carries that precision, so the value is passed back unchanged.
wlr-randr --json |
  jq -r '
    .[]
    | select(.enabled)
    | . as $output
    | (first(.modes[] | select(.preferred)) // first(.modes[] | select(.current))) as $native
    | [.modes[] | select(.width == $native.width and .height == $native.height)]
    | max_by(.refresh)
    | [$output.name, .width, .height, (.refresh | tostring)]
    | @tsv' |
  while IFS=$'\t' read -r name width height refresh; do
    if ((width >= 3840)); then
      scale=2
    elif ((width >= 2560)); then
      scale=1.25
    else
      scale=1
    fi
    echo "recovery-displays: $name ${width}x${height} at $refresh Hz, scale $scale"
    # A mode the link cannot carry is rejected before anything changes; fall
    # back to the monitor's preferred mode then.
    wlr-randr --output "$name" --mode "${width}x${height}@${refresh}Hz" --scale "$scale" ||
      wlr-randr --output "$name" --preferred --scale "$scale" ||
      echo "recovery-displays: could not configure $name" >&2
  done
