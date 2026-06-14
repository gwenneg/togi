---
name: disable
description: Disable togi friction capture for you alone — this repo or all your repos; teammates unaffected. Use when the user wants to turn off, stop, opt out of, or pause togi capture.
---

# Instructions

Use `AskUserQuestion` to ask: **"Disable friction capture at which scope?"** Options: **This repo only** / **All my repos**.

## This repo only

```bash
mkdir -p .claude
touch .claude/settings.local.json
jq -s '(.[0] // {}) | .env.TOGI_ENABLED = "0"' .claude/settings.local.json > .claude/settings.local.json.tmp \
  && mv .claude/settings.local.json.tmp .claude/settings.local.json
```

Then output:

```
Friction capture is disabled for you in this repo — teammates are unaffected.
This also overrides a global opt-in, for this repo only.
Turn it back on any time with /togi:enable.
```

## All my repos

```bash
touch ~/.claude/settings.json
jq -s '(.[0] // {}) | .env.TOGI_ENABLED = "0"' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

Then output:

```
Friction capture is disabled for you in all repos on this machine — teammates are unaffected.
Exception: repos where you enabled togi individually keep their own setting — run /togi:disable in those repos too.
Turn it back on in a single repo by running /togi:enable there, or run /togi:enable and choose `All my repos` to turn it back on globally.
```
