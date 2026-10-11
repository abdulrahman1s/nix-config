#!/bin/sh
set -eu

stop_file=/tmp/nix-cache-stop-uploader
rm -f "$stop_file"

while [ ! -e "$stop_file" ]; do
  elapsed=0
  while [ "$elapsed" -lt 300 ] && [ ! -e "$stop_file" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  [ ! -e "$stop_file" ] || break
  nice -n 10 sh .github/scripts/publish-nix-cache.sh --packages-only
done

# Capture outputs completed during the last sleep interval.
nice -n 10 sh .github/scripts/publish-nix-cache.sh --packages-only
