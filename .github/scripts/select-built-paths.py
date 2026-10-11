#!/usr/bin/env python3
"""Select every output built by the runner for cache publication."""

import sys
from pathlib import Path


record_file = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/nix-cache-built-paths")
exclude_file = Path(sys.argv[2]) if len(sys.argv) > 2 else None
records = [
    line.split("\t", 1)
    for line in record_file.read_text().splitlines()
    if "\t" in line
]
# Fixed-output downloads can be runtime references of another cached output. If
# they are absent from every upstream cache, omitting them makes a local rebuild
# run their download derivations even though the main package is cached.
paths = {path for _, path in records}

if exclude_file is not None and exclude_file.exists():
    paths.difference_update(exclude_file.read_text().splitlines())

for path in sorted(paths):
    print(path)
