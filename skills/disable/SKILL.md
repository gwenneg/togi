---
name: disable
description: Disable togi friction capture for you only — not committed, not shared
allowed-tools:
  - Bash(mkdir*)
  - Bash(jq*)
---

# Instructions

```bash
mkdir -p .claude
[ -f .claude/settings.local.json ] || echo '{}' > .claude/settings.local.json
jq '.env.TOGI_ENABLED = "0"' .claude/settings.local.json > .claude/settings.local.json.tmp \
  && mv .claude/settings.local.json.tmp .claude/settings.local.json
```

Then output:

```
Friction capture disabled for this repo.
To re-enable, run /togi:enable.
```
