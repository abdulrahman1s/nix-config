#!/bin/sh
set -eu
: "${NIX_CACHE_SIGNING_KEY:?Missing NIX_CACHE_SIGNING_KEY secret}"

cache=$(mktemp -d)
new_paths=/tmp/nix-cache-new-paths
uploaded_paths=/tmp/nix-cache-uploaded-paths
packages_only=${1:-}
signing_key=
trap 'rm -rf "$cache"; [ -z "$signing_key" ] || rm -f "$signing_key"' EXIT
touch "$uploaded_paths"

if [ -s /tmp/nix-cache-built-paths ]; then
  python3 .github/scripts/select-built-paths.py \
    /tmp/nix-cache-built-paths "$uploaded_paths" > "$new_paths"
else
  : > "$new_paths"
fi

if [ -s "$new_paths" ]; then
  signing_key=$(mktemp)
  chmod 0600 "$signing_key"
  printf '%s\n' "$NIX_CACHE_SIGNING_KEY" > "$signing_key"

  nix copy --no-recursive --stdin --to "file://$cache?secret-key=$signing_key&compression=zstd" < "$new_paths"
  python3 .github/scripts/upload-nix-cache.py "$cache"
  cat "$new_paths" >> "$uploaded_paths"
  sort -u -o "$uploaded_paths" "$uploaded_paths"
  echo "Uploaded $(wc -l < "$new_paths") newly built store paths to private R2."
else
  echo 'No new package outputs were built on this runner.'
fi

if [ "$packages_only" != --packages-only ]; then
  python3 .github/scripts/upload-nix-cache.py \
    --metadata ci/failed-targets /tmp/nix-cache-failed-targets-next
fi
