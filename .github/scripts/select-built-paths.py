#!/usr/bin/env python3
"""Select runner-built outputs, excluding downloaded fixed-output sources."""

import json
import subprocess
import sys
from pathlib import Path


record_file = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/nix-cache-built-paths")
exclude_file = Path(sys.argv[2]) if len(sys.argv) > 2 else None
include_file = Path(sys.argv[3]) if len(sys.argv) > 3 else None
required_for_evaluation = (
    set(include_file.read_text().splitlines())
    if include_file is not None and include_file.exists()
    else set()
)
records = [
    line.split("\t", 1)
    for line in record_file.read_text().splitlines()
    if "\t" in line
]
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
    if path in required_for_evaluation or all(
        "hash" not in output for output in derivation["outputs"].values()
    ):
        paths.add(path)

if exclude_file is not None and exclude_file.exists():
    paths.difference_update(exclude_file.read_text().splitlines())

for path in sorted(paths):
    print(path)
