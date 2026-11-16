set -Eeuo pipefail

# Runs one recovery tool as root from a launcher entry. The window stays open
# afterwards so its output, including any error, can be read.
sudo_wrapper="/run/wrappers/bin/sudo"

finish() {
  echo
  read -r -p "Press Enter to close this window. " _ || true
  exit "$1"
}

if [[ $# -eq 0 ]]; then
  echo "usage: recovery-action COMMAND [ARGUMENT...]" >&2
  finish 2
fi

if ! command_path="$(command -v "$1")"; then
  echo "recovery-action: $1 is not installed" >&2
  finish 127
fi

echo "Running as root: $*"
echo "Enter your password when asked."
echo

status=0
"$sudo_wrapper" -- "$command_path" "${@:2}" || status=$?

echo
if ((status == 0)); then
  echo "Finished."
else
  echo "Stopped with exit status $status."
fi
finish "$status"
