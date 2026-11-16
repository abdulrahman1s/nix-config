"""Reduce decorative background work in the pinned S4MP launcher."""
import hashlib
from pathlib import Path
import sys

import brotli

source, destination = map(Path, sys.argv[1:])
data = source.read_bytes()
if hashlib.sha256(data).hexdigest() != "448f5abb40eb05afda5c2e76d793d79d3dbdd6641d95d93718eba58c0e6fead0":
    raise ValueError("Review the embedded assets before updating S4MP")
key = b"/assets/index-sR9Y6s8f.css"
if data.count(key) != 1:
    raise ValueError("Expected one bundled S4MP stylesheet")
start = data.index(key) + len(key)
size = 50576
stylesheet = brotli.decompress(data[start:start + size])
# Wine's software compositor also saturates a core while scrolling translucent
# panels at 2x scale. Flatten decorative layers and remove entrance/hover motion;
# retain loading animations, focus shadows and grayscale disabled-pack icons.
stylesheet += b"""
@media(prefers-reduced-motion:reduce){
*,*::before,*::after{backdrop-filter:none!important;transition:none!important}
.bg-layer{display:none!important}
.plumbob,.nav-logo{filter:none!important}
.settings-content{background:#122035!important;contain:layout paint}
.bg-layer::before,.bg-layer::after,.plumbob,.patron-word-cloud__chart,.status-dot,
.settings-section,.section-header,.section-controls,.tips-box,.status-bar,
.hero-title,.hero-subtitle,.cta-group,.glass-card{animation:none!important}
}
"""
compressed = brotli.compress(stylesheet, quality=11)
if len(compressed) > size:
    raise ValueError("Patched stylesheet exceeds its embedded asset slot")
# Tauri's streaming Brotli reader stops at the end of the compressed stream.
# Preserve the slot size so the executable's asset offsets remain unchanged.
data = data[:start] + compressed.ljust(size, b"\0") + data[start + size:]

# The decorative patron heart also builds a high-DPI canvas in a worker. At 2x
# scale it can consume a core even after its UI times out. Skip that component
# in reduced-motion mode; authentication, lobbies and game preparation are intact.
key = b"/assets/index-DHhc2Jxk.js"
if data.count(key) != 1:
    raise ValueError("Expected one bundled S4MP JavaScript entry point")
start = data.index(key) + len(key)
size = 217586
script = brotli.decompress(data[start:start + size])
component = b"function HC(){let e=(0,E.useRef)(null)"
if script.count(component) != 1:
    raise ValueError("Review the patron-heart component before updating S4MP")
script = script.replace(component, b'function HC(){if(window.matchMedia("(prefers-reduced-motion: reduce)").matches)return null;let e=(0,E.useRef)(null)')
compressed = brotli.compress(script, quality=11)
if len(compressed) > size:
    raise ValueError("Patched JavaScript exceeds its embedded asset slot")
destination.write_bytes(data[:start] + compressed.ljust(size, b"\0") + data[start + size:])
destination.with_suffix(".sha256").write_text(hashlib.sha256(destination.read_bytes()).hexdigest() + "\n")
