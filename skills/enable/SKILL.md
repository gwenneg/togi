---
name: enable
description: Re-enable togi friction capture after disabling it — personal, not committed
allowed-tools:
  - Bash(mkdir*)
  - Bash(touch .claude/*)
  - Bash(jq*)
  - Bash(mv .claude/*)
---

# Instructions

```bash
mkdir -p .claude
touch .claude/settings.local.json
jq -s '(.[0] // {}) | .env.TOGI_ENABLED = "1"' .claude/settings.local.json > .claude/settings.local.json.tmp
mv .claude/settings.local.json.tmp .claude/settings.local.json
```

Then output:

```
Friction capture re-enabled.
Run /togi:disable at any time to opt out.
```
