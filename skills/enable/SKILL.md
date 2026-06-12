---
name: enable
description: Enable friction capture for you alone — this repo or all your repos; teammates unaffected
---

# Instructions

If this skill was invoked with the argument `repo` or `all` (e.g. by `/togi:setup`), skip the question and apply that scope directly.
Otherwise, use `AskUserQuestion` to ask: **"Enable friction capture at which scope?"** Options: **This repo only** / **All my repos**.

## This repo only (`repo`)

```bash
mkdir -p .claude
touch .claude/settings.local.json
jq -s '(.[0] // {}) | .env.TOGI_ENABLED = "1"' .claude/settings.local.json > .claude/settings.local.json.tmp \
  && mv .claude/settings.local.json.tmp .claude/settings.local.json
```

Then output:

```
Friction capture is on for you in this repo — teammates are unaffected.
This also overrides a global opt-out, for this repo only.
Turn it off any time with /togi:disable.
```

## All my repos (`all`)

```bash
touch ~/.claude/settings.json
jq -s '(.[0] // {}) | .env.TOGI_ENABLED = "1"' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
  && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
```

Then output:

```
Friction capture is on for you in all repos on this machine — teammates are unaffected.
Exception: repos where you disabled togi individually keep their own setting — run /togi:enable in those repos too.
Turn it off in a single repo by running /togi:disable there, or run /togi:disable and choose `All my repos` to turn it off globally.
```
