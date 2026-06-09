---
name: disable
description: Disable togi friction capture for you only — not committed, not shared
allowed-tools:
  - Bash(set-enabled.sh 0)
---

# Instructions

Run the following commands:

```bash
set-enabled.sh 0
echo "Friction capture disabled for this repo."
echo "To re-enable, run /togi:enable."
```

Show the output to the user verbatim.
