#!/usr/bin/env python3
"""Refresh binary release pins; flake inputs are updated by the workflow."""

import json
import os
import pathlib
import subprocess
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parent
VERSIONS = ROOT / "versions.json"


def get_json(url):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "nix-packages-updater"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
        return json.load(response)


def release(repo):
    return get_json(f"https://api.github.com/repos/{repo}/releases/latest")


def asset_url(data, name):
    for asset in data["assets"]:
        if asset["name"] == name:
            return asset["browser_download_url"]
    raise RuntimeError(f"Missing {name} in {data['html_url']}")


def prefetch(url):
    result = subprocess.check_output(["nix", "store", "prefetch-file", "--json", url], text=True)
    return json.loads(result)["hash"]


def main():
    versions = json.loads(VERSIONS.read_text())

    codex_release = release("openai/codex")
    codex_version = codex_release["tag_name"].removeprefix("rust-v")
    if codex_version != versions["codex"]["version"]:
        versions["codex"] = {
            "version": codex_version,
            "hash": prefetch(asset_url(codex_release, "codex-x86_64-unknown-linux-musl.tar.gz")),
        }

    claude_release = release("anthropics/claude-code")
    claude_version = claude_release["tag_name"].removeprefix("v")
    if claude_version != versions["claude"]["version"]:
        manifest = get_json(f"https://downloads.claude.ai/claude-code-releases/{claude_version}/manifest.json")
        if manifest["version"] != claude_version:
            raise RuntimeError("Claude release and official manifest disagree")
        versions["claude"] = {
            "version": claude_version,
            "sha256": manifest["platforms"]["linux-x64"]["checksum"],
        }

    brave_release = release("brave/brave-browser")
    brave_version = brave_release["tag_name"].removeprefix("v")
    if brave_version != versions["brave-origin"]["version"]:
        versions["brave-origin"] = {
            "version": brave_version,
            "hash": prefetch(asset_url(brave_release, f"brave-origin_{brave_version}_amd64.deb")),
        }

    VERSIONS.write_text(json.dumps(versions, indent=2) + "\n")
    for name, info in versions.items():
        print(f"{name}: {info['version']}")


if __name__ == "__main__":
    main()
