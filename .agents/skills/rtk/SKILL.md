---
name: rtk
description: Use RTK for every shell command to keep command output concise in agent sessions.
---

# RTK

Prefix every shell command with `rtk`.

```bash
rtk git status
rtk cargo test
rtk npm run build
rtk pytest -q
```

Use `rtk proxy <command>` when unfiltered output is required. Use `rtk gain` or
`rtk gain --history` to inspect token savings.
