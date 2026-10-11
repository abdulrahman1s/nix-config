#!/bin/sh
set -eu
: "${NIX_CACHE_SIGNING_KEY:?Missing NIX_CACHE_SIGNING_KEY secret}"

cache=/tmp/nix-cache-upload
closure=/tmp/nix-cache-closure
new_paths=/tmp/nix-cache-new-paths

nix-store --query --requisites /tmp/nix-cache-system | sort -u > "$closure"
if [ ! -s /tmp/nix-cache-built-paths ]; then
  echo 'No new paths were built; the existing R2 cache is current.'
  exit 0
fi

sort -u /tmp/nix-cache-built-paths | comm -12 - "$closure" > "$new_paths"
if [ ! -s "$new_paths" ]; then
  echo 'No newly built paths belong to the system closure.'
  exit 0
fi

signing_key=$(mktemp)
trap 'rm -f "$signing_key"' EXIT
chmod 0600 "$signing_key"
printf '%s\n' "$NIX_CACHE_SIGNING_KEY" > "$signing_key"

nix copy --no-recursive --stdin --to "file://$cache?secret-key=$signing_key&compression=zstd" < "$new_paths"
python3 .github/scripts/upload-nix-cache.py "$cache"
echo "Uploaded $(wc -l < "$new_paths") newly built store paths to private R2."
