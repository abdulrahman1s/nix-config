#!/bin/sh
set -eu

stop_file=/tmp/nix-cache-stop-uploader
rm -f "$stop_file"

while [ ! -e "$stop_file" ]; do
  elapsed=0
  while [ "$elapsed" -lt 60 ] && [ ! -e "$stop_file" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  [ ! -e "$stop_file" ] || break
  if ! nice -n 10 sh .github/scripts/publish-nix-cache.sh --packages-only; then
    echo 'Incremental cache upload failed; it will be retried in one minute.' >&2
  fi
done
