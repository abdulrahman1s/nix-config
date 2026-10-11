#!/bin/sh
set -eu

# Nix only runs this hook for outputs built on the runner, not substitutions.
for path in $OUT_PATHS; do
  printf '%s\n' "$path" >> /tmp/nix-cache-built-paths
done
