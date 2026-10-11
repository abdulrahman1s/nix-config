#!/usr/bin/env python3
"""Select runner-built outputs, excluding downloaded fixed-output sources."""

import json
import subprocess
import sys
from pathlib import Path


record_file = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/nix-cache-built-paths")
records = [line.split("\t", 1) for line in record_file.read_text().splitlines()]
drvs = sorted({drv for drv, _ in records})
result = subprocess.run(
    ["nix", "derivation", "show", *drvs],
    check=True,
    capture_output=True,
    text=True,
)
derivations = json.loads(result.stdout)["derivations"]

paths = set()
for drv, path in records:
    derivation = derivations[Path(drv).name]
    if all("hash" not in output for output in derivation["outputs"].values()):
        paths.add(path)

for path in sorted(paths):
    print(path)
