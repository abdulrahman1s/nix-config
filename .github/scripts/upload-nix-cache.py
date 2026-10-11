#!/usr/bin/env python3
"""Upload a signed local Nix binary cache to the private R2 Worker."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlencode


BASE_URL = os.environ["NIX_CACHE_URL"].rstrip("/")
TOKEN = os.environ["NIX_CACHE_WRITE_TOKEN"]
PART_SIZE = 8 * 1024 * 1024
SINGLE_UPLOAD_LIMIT = 50 * 1024 * 1024


def send(method, key, auth_config, data=None, path=None, **query):
    url = f"{BASE_URL}/upload/{quote(key, safe='/')}"
    if query:
        url += "?" + urlencode(query)
    command = [
        "curl", "--config", auth_config, "--silent", "--show-error",
        "--fail-with-body", "--retry", "3", "--retry-all-errors",
        "--connect-timeout", "10", "--max-time", "180",
        "--request", method, "--url", url,
    ]
    payload = None
    if data is not None:
        payload = tempfile.NamedTemporaryFile(prefix="nix-cache-payload-", delete=True)
        payload.write(data)
        payload.flush()
        path = payload.name
    if path is not None:
        command.extend(("--data-binary", f"@{path}"))
    try:
        result = subprocess.run(command, capture_output=True)
    finally:
        if payload is not None:
            payload.close()
    if result.returncode:
        raise RuntimeError(f"upload of {key} failed: {result.stderr.decode().strip()}")
    return result.stdout


def upload(key, path, auth_config):
    if path.stat().st_size <= SINGLE_UPLOAD_LIMIT:
        send("PUT", key, auth_config, path=path)
        return

    upload_id = json.loads(send("POST", key, auth_config, multipart="start"))["uploadId"]
    parts = []
    try:
        with path.open("rb") as source:
            part_number = 1
            while chunk := source.read(PART_SIZE):
                part = json.loads(send(
                    "PUT", key, auth_config, chunk, multipart="part",
                    uploadId=upload_id, partNumber=part_number,
                ))
                parts.append(part)
                part_number += 1
        send(
            "POST", key, auth_config, json.dumps({"parts": parts}).encode(),
            multipart="complete", uploadId=upload_id,
        )
    except Exception:
        try:
            send("DELETE", key, auth_config, multipart="abort", uploadId=upload_id)
        except Exception:
            pass
        raise


def main():
    if not BASE_URL.startswith("https://") or not TOKEN:
        raise RuntimeError("NIX_CACHE_URL and NIX_CACHE_WRITE_TOKEN are required")
    cache = Path(sys.argv[1])
    nars = sorted((cache / "nar").glob("*.nar.zst"))
    narinfos = sorted(cache.glob("*.narinfo"))
    with tempfile.NamedTemporaryFile(mode="w", prefix="nix-cache-curl-", delete=True) as auth:
        auth.write(f'header = "Authorization: Bearer {TOKEN}"\n')
        auth.flush()
        for path in nars:
            upload(f"nar/{path.name}", path, auth.name)
        upload("nix-cache-info", cache / "nix-cache-info", auth.name)
        for path in narinfos:
            upload(path.name, path, auth.name)
    print(f"Uploaded {len(nars)} NARs and {len(narinfos)} signed narinfo files")


if __name__ == "__main__":
    main()
