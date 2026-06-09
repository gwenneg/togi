---
name: enable
description: Re-enable togi friction capture after disabling it — personal, not committed
allowed-tools:
  - Bash(mkdir*)
  - Bash(jq*)
---

# Instructions

```bash
mkdir -p .claude
[ -f .claude/settings.local.json ] || echo '{}' > .claude/settings.local.json
jq '.env.TOGI_ENABLED = "1"' .claude/settings.local.json > .claude/settings.local.json.tmp
mv .claude/settings.local.json.tmp .claude/settings.local.json
```

Then output:

```
Friction capture re-enabled.
Run /togi:disable at any time to opt out.
```
