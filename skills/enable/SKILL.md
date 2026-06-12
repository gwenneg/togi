---
name: enable
description: Enable friction capture for you alone — git-ignored local setting, teammates unaffected
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
Friction capture is on for you in this repo — teammates are unaffected.
Turn it off any time with /togi:disable.
```
