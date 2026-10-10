#!/usr/bin/env bash
# Refresh binary release pins; flake inputs are updated by the workflow.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
versions_file="$root/versions.json"
tmp_file=$(mktemp "$root/.versions.json.XXXXXX")
trap 'rm -f -- "$tmp_file"' EXIT

headers=(-H 'Accept: application/vnd.github+json' -H 'User-Agent: nix-packages-updater')
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

get_json() {
  curl -fsSL "${headers[@]}" "$1"
}

release() {
  get_json "https://api.github.com/repos/$1/releases/latest"
}

asset_url() {
  jq -er --arg name "$2" '.assets[] | select(.name == $name) | .browser_download_url' <<< "$1"
}

prefetch() {
  nix store prefetch-file --json "$1" | jq -er '.hash'
}

versions=$(< "$versions_file")

codex_release=$(release openai/codex)
codex_version=$(jq -er '.tag_name | sub("^rust-v"; "")' <<< "$codex_release")
if [[ $codex_version != "$(jq -er '.codex.version' <<< "$versions")" ]]; then
  codex_url=$(asset_url "$codex_release" codex-package-x86_64-unknown-linux-musl.tar.gz)
  codex_hash=$(prefetch "$codex_url")
  versions=$(jq --arg version "$codex_version" --arg hash "$codex_hash" \
    '.codex = {version: $version, hash: $hash}' <<< "$versions")
fi

chatgpt_info=$(curl -fsSL \
  https://persistent.oaistatic.com/codex-app-prod/linux/deb/dists/stable/main/binary-amd64/Packages.gz \
  | gzip -dc | awk 'BEGIN { RS = ""; FS = "\n" } $1 == "Package: chatgpt" { package = $0 } END { print package }')
chatgpt_version=$(awk -F ': ' '$1 == "Version" { print $2 }' <<< "$chatgpt_info")
chatgpt_sha256=$(awk -F ': ' '$1 == "SHA256" { print $2 }' <<< "$chatgpt_info")
chatgpt_filename=$(awk -F ': ' '$1 == "Filename" { print $2 }' <<< "$chatgpt_info")
if [[ -z $chatgpt_version || ! $chatgpt_sha256 =~ ^[0-9a-f]{64}$ \
  || $chatgpt_filename != "pool/main/c/chatgpt/chatgpt_${chatgpt_version}_amd64.deb" ]]; then
  echo 'Missing or invalid ChatGPT package metadata' >&2
  exit 1
fi
if [[ $chatgpt_version != "$(jq -er '.chatgpt.version' <<< "$versions")" ]]; then
  chatgpt_hash=$(nix hash convert --hash-algo sha256 --to sri "$chatgpt_sha256")
  versions=$(jq --arg version "$chatgpt_version" --arg hash "$chatgpt_hash" \
    '.chatgpt = {version: $version, hash: $hash}' <<< "$versions")
fi

photocraft_release=$(release storytold/photocraft)
photocraft_version=$(jq -er '.tag_name | sub("^v"; "")' <<< "$photocraft_release")
if [[ $photocraft_version != "$(jq -er '.photocraft.version' <<< "$versions")" ]]; then
  photocraft_asset="photocraft-${photocraft_version}-linux-x86_64.tar.gz"
  asset_url "$photocraft_release" "$photocraft_asset" >/dev/null
  photocraft_sums_url=$(asset_url "$photocraft_release" SHA256SUMS.txt)
  photocraft_sha256=$(get_json "$photocraft_sums_url" | awk -v asset="$photocraft_asset" '$2 == asset { print $1 }')
  if [[ ! $photocraft_sha256 =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Missing or invalid PhotoCraft release checksum' >&2
    exit 1
  fi
  photocraft_hash=$(nix hash convert --hash-algo sha256 --to sri "$photocraft_sha256")
  versions=$(jq --arg version "$photocraft_version" --arg hash "$photocraft_hash" \
    '.photocraft = {version: $version, hash: $hash}' <<< "$versions")
fi

filmcraft_release=$(release storytold/filmcraft)
filmcraft_version=$(jq -er '.tag_name | sub("^v"; "")' <<< "$filmcraft_release")
if [[ $filmcraft_version != "$(jq -er '.filmcraft.version' <<< "$versions")" ]]; then
  filmcraft_asset="filmcraft-${filmcraft_version}-linux-x86_64.tar.gz"
  asset_url "$filmcraft_release" "$filmcraft_asset" >/dev/null
  filmcraft_sums_url=$(asset_url "$filmcraft_release" SHA256SUMS.txt)
  filmcraft_sha256=$(get_json "$filmcraft_sums_url" | awk -v asset="$filmcraft_asset" '$2 == asset { print $1 }')
  if [[ ! $filmcraft_sha256 =~ ^[0-9a-f]{64}$ ]]; then
    echo 'Missing or invalid FilmCraft release checksum' >&2
    exit 1
  fi
  filmcraft_hash=$(nix hash convert --hash-algo sha256 --to sri "$filmcraft_sha256")
  versions=$(jq --arg version "$filmcraft_version" --arg hash "$filmcraft_hash" \
    '.filmcraft = {version: $version, hash: $hash}' <<< "$versions")
fi

sklauncher_release=$(release sklauncher/binaries)
sklauncher_version=$(jq -er '.tag_name | capture("^v(?<version>4\\.[0-9]+\\.[0-9]+)$").version' <<< "$sklauncher_release")
if [[ $sklauncher_version != "$(jq -er '.sklauncher.version' <<< "$versions")" ]]; then
  sklauncher_asset="SKlauncher-${sklauncher_version}-x86_64.AppImage"
  sklauncher_url=$(asset_url "$sklauncher_release" "$sklauncher_asset")
  sklauncher_digest=$(jq -er --arg name "$sklauncher_asset" \
    '.assets[] | select(.name == $name) | .digest | capture("^sha256:(?<hash>[0-9a-f]{64})$").hash' \
    <<< "$sklauncher_release")
  sklauncher_hash=$(nix hash convert --hash-algo sha256 --to sri "$sklauncher_digest")
  versions=$(jq --arg version "$sklauncher_version" --arg hash "$sklauncher_hash" \
    '.sklauncher = {version: $version, hash: $hash}' <<< "$versions")
fi

claude_release=$(release anthropics/claude-code)
claude_version=$(jq -er '.tag_name | sub("^v"; "")' <<< "$claude_release")
if [[ $claude_version != "$(jq -er '.claude.version' <<< "$versions")" ]]; then
  manifest=$(get_json "https://downloads.claude.ai/claude-code-releases/$claude_version/manifest.json")
  if [[ $(jq -er '.version' <<< "$manifest") != "$claude_version" ]]; then
    echo 'Claude release and official manifest disagree' >&2
    exit 1
  fi
  claude_sha256=$(jq -er '.platforms["linux-x64"].checksum' <<< "$manifest")
  versions=$(jq --arg version "$claude_version" --arg sha256 "$claude_sha256" \
    '.claude = {version: $version, sha256: $sha256}' <<< "$versions")
fi

brave_release=$(release brave/brave-browser)
brave_version=$(jq -er '.tag_name | sub("^v"; "")' <<< "$brave_release")
if [[ $brave_version != "$(jq -er '."brave-origin".version' <<< "$versions")" ]]; then
  brave_url=$(asset_url "$brave_release" "brave-origin_${brave_version}_amd64.deb")
  brave_hash=$(prefetch "$brave_url")
  versions=$(jq --arg version "$brave_version" --arg hash "$brave_hash" \
    '."brave-origin" = {version: $version, hash: $hash}' <<< "$versions")
fi

printf '%s\n' "$versions" > "$tmp_file"
if ! cmp -s -- "$tmp_file" "$versions_file"; then
  chmod --reference="$versions_file" "$tmp_file"
  mv -- "$tmp_file" "$versions_file"
fi
jq -r 'to_entries[] | "\(.key): \(.value.version)"' <<< "$versions"
