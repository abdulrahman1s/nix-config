#!/usr/bin/env bash
set -euo pipefail

# Direct .drv builds do not inherit flake.nix's nixConfig automatically.
cache_config=$(nix eval --impure --json --expr '(import ./flake.nix).nixConfig')
export NIX_CONFIG="${NIX_CONFIG:-}
extra-substituters = $(jq -r '."extra-substituters" | join(" ")' <<< "$cache_config")
extra-trusted-public-keys = $(jq -r '."extra-trusted-public-keys" | join(" ")' <<< "$cache_config")"

# Evaluate installed packages without realizing the full NixOS system closure.
nix eval --json .#nixosConfigurations.default \
  --apply 'n: builtins.map (p: "${p.drvPath}^${p.outputName}") (n.config.environment.systemPackages ++ n.config.users.users.abdulrahman.packages ++ n.config.services.udev.packages ++ n.config.boot.extraModulePackages ++ [ n.config.boot.kernelPackages.kernel ])' \
  --no-update-lock-file | jq -r '.[]' | sort -u > /tmp/nix-cache-candidates

mapfile -t targets < /tmp/nix-cache-candidates

# A dry run consults the configured substituters without downloading their paths.
nix build --dry-run --no-link --no-update-lock-file "${targets[@]}" \
  2> /tmp/nix-cache-plan
awk '/^  \/nix\/store\/.*\.drv$/ { print $1 }' /tmp/nix-cache-plan | sort -u \
  > /tmp/nix-cache-planned-builds
cut -d '^' -f 1 /tmp/nix-cache-candidates | sort -u > /tmp/nix-cache-candidate-drvs
comm -12 /tmp/nix-cache-candidate-drvs /tmp/nix-cache-planned-builds \
  > /tmp/nix-cache-needed

mapfile -t needed_drvs < /tmp/nix-cache-needed
echo "Building ${#needed_drvs[@]} installed packages absent from substituters."
if (( ${#needed_drvs[@]} == 0 )); then
  exit 0
fi

targets=()
while IFS= read -r target; do
  if grep -Fxq "${target%%^*}" /tmp/nix-cache-needed; then
    targets+=("$target")
  fi
done < /tmp/nix-cache-candidates
nix build --keep-going --no-link --no-update-lock-file "${targets[@]}"
