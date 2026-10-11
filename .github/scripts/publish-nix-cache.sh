#!/bin/sh
set -eu
: "${NIX_CACHE_SIGNING_KEY:?Missing NIX_CACHE_SIGNING_KEY secret}"

cache=/tmp/nix-cache-upload
new_paths=/tmp/nix-cache-new-paths

if [ -s /tmp/nix-cache-built-paths ]; then
  python3 .github/scripts/select-built-paths.py > "$new_paths"
else
  : > "$new_paths"
fi

if [ -s "$new_paths" ]; then
  signing_key=$(mktemp)
  trap 'rm -f "$signing_key"' EXIT
  chmod 0600 "$signing_key"
  printf '%s\n' "$NIX_CACHE_SIGNING_KEY" > "$signing_key"

  nix copy --no-recursive --stdin --to "file://$cache?secret-key=$signing_key&compression=zstd" < "$new_paths"
  python3 .github/scripts/upload-nix-cache.py "$cache"
  echo "Uploaded $(wc -l < "$new_paths") newly built store paths to private R2."
else
  echo 'No new package outputs were built on this runner.'
fi

python3 .github/scripts/upload-nix-cache.py \
  --metadata ci/failed-targets /tmp/nix-cache-failed-targets-next
