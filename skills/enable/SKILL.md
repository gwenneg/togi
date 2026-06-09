---
name: enable
description: Re-enable togi friction capture after disabling it — personal, not committed
allowed-tools:
  - Bash(set-enabled.sh 1)
---

# Instructions

Run the following commands:

```bash
set-enabled.sh 1
echo "Friction capture re-enabled."
echo "Run /togi:disable at any time to opt out."
```

Show the output to the user verbatim.
