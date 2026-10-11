#!/bin/sh
set -eu
set -f

# Nix only runs this hook for outputs built on the runner, not substitutions.
for path in $OUT_PATHS; do
  printf '%s\t%s\n' "$DRV_PATH" "$path" >> /tmp/nix-cache-built-paths
done
