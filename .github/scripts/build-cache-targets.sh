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
kernel_drv=$(nix eval --raw \
  .#nixosConfigurations.default.config.boot.kernelPackages.kernel.drvPath \
  --no-update-lock-file)
export kernel_drv

mapfile -t targets < /tmp/nix-cache-candidates

# A dry run consults the configured substituters without downloading their paths.
nix build --dry-run --no-link --no-update-lock-file "${targets[@]}" \
  2> /tmp/nix-cache-plan
awk '/^  \/nix\/store\/.*\.drv$/ { print $1 }' /tmp/nix-cache-plan | sort -u \
  > /tmp/nix-cache-planned-builds
cut -d '^' -f 1 /tmp/nix-cache-candidates | sort -u > /tmp/nix-cache-candidate-drvs
comm -12 /tmp/nix-cache-candidate-drvs /tmp/nix-cache-planned-builds \
  > /tmp/nix-cache-needed

needed_targets=()
while IFS= read -r target; do
  if grep -Fxq "${target%%^*}" /tmp/nix-cache-needed; then
    needed_targets+=("$target")
  fi
done < /tmp/nix-cache-candidates

failure_state=/tmp/nix-cache-failed-targets
next_failure_state=/tmp/nix-cache-failed-targets-next
: > "$failure_state"
: > "$next_failure_state"
status=$(curl --netrc-file "$HOME/.netrc" --silent --show-error \
  --retry 3 --connect-timeout 10 --max-time 30 \
  --output "$failure_state" --write-out '%{http_code}' \
  https://abdulrahman1s-nix-cache.citizen6775.workers.dev/ci/failed-targets)
case "$status" in
  200) sort -u -o "$failure_state" "$failure_state" ;;
  404) : > "$failure_state" ;;
  *) echo "Failed build state returned HTTP $status" >&2; exit 1 ;;
esac

retry_failed=${RETRY_FAILED:-false}
targets_to_build=()
for target in "${needed_targets[@]}"; do
  if [[ "$retry_failed" != true ]] && grep -Fxq "$target" "$failure_state"; then
    printf '%s\n' "$target" >> "$next_failure_state"
  else
    targets_to_build+=("$target")
  fi
done

echo "${#needed_targets[@]} installed packages are absent from substituters."
echo "Skipping $(wc -l < "$next_failure_state") unchanged derivations that failed before."
echo "Building ${#targets_to_build[@]} package derivations."

failure_dir=$(mktemp -d)
export failure_dir
build_target() {
  local target=$1
  local limit=45m
  local result
  if [[ "${target%%^*}" == "$kernel_drv" ]]; then
    limit=120m
  fi
  result=$(printf '%s' "$target" | sha256sum | cut -d ' ' -f 1)
  if ! timeout --signal=TERM --kill-after=2m "$limit" \
    nix build --no-link --no-update-lock-file \
      --option max-jobs 1 --option cores 2 "$target"; then
    printf '%s\n' "$target" > "$failure_dir/$result"
  fi
}
export -f build_target

if (( ${#targets_to_build[@]} > 0 )); then
  printf '%s\0' "${targets_to_build[@]}" \
    | xargs -0 -r -n 1 -P 2 bash -c 'build_target "$1"' _
fi

for failure in "$failure_dir"/*; do
  [[ -e "$failure" ]] || continue
  cat "$failure" >> "$next_failure_state"
done
sort -u -o "$next_failure_state" "$next_failure_state"

failed_count=$(wc -l < "$next_failure_state")
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '### Nix cache build'
    echo
    echo "- Missing from binary caches: ${#needed_targets[@]}"
    echo "- Attempted now: ${#targets_to_build[@]}"
    echo "- Remembered failures: $failed_count"
    if (( failed_count > 0 )); then
      echo
      echo 'Failed derivations are skipped until their hash changes or a manual run enables **Retry unchanged failures**.'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if (( failed_count > 0 )); then
  echo "$failed_count package derivations remain unavailable; successful builds will still be published."
fi
