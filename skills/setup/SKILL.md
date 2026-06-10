---
name: setup
description: Install togi — session hooks that capture AI friction events and remind developers to improve context docs
allowed-tools:
  - Write
  - Read
  - Edit
  - Bash(mkdir*)
  - Bash(jq*)
  - Bash(grep*)
  - Bash(git add *)
  - Bash(git branch *)
  - Bash(git checkout *)
  - Bash(git commit *)
  - Bash(git push *)
  - Bash(gh pr create)
---

# Instructions

## Phase 1: Explain and get consent

Output the following text verbatim before taking any other action:

> **Togi** (研ぎ, to sharpen) is a friction-driven feedback loop for AI context docs. During each session, Claude detects friction events — corrections, clarifications, mistakes, tool denials — and writes them directly to `.claude/friction/` as they occur. Once enough friction events accumulate, a startup reminder prompts the team to run `/togi:update-context-docs`, which turns those events into doc improvements via a pull request.
>
> **Before proceeding, read this carefully:**
>
> **What this installs.** This phase configures your project: it adds the togi marketplace entry and plugin to `.claude/settings.json` and updates `.gitignore`. The SessionStart and Stop hooks are managed by the plugin itself via `hooks/hooks.json` — nothing is written to your project for those.

Use `AskUserQuestion` to ask: **"Do you want to proceed with the installation?"** Options: **Yes, proceed** / **No, cancel**.

If the user selects No, stop.

## Phase 2: Configure settings.json and .gitignore

Output the following text verbatim before taking any other action in this phase:

> This phase configures `.claude/settings.json` with the togi marketplace registration and plugin enablement, and updates `.gitignore` with the togi allowlist. All existing content is preserved.
>
> **Friction capture is enabled by default for everyone on the team.** Events are written as local markdown files to `.claude/friction/` (git-ignored). At the end of every turn, the Stop hook prompts Claude to review the turn for friction and write any qualifying events before stopping. Any developer can opt out personally with `/togi:disable`, which writes to `.claude/settings.local.json` (not committed).
>
> You can set `TOGI_EVENT_THRESHOLD` (default: `5`) to control how many friction events accumulate before the startup reminder appears.

### 1. settings.json

```bash
mkdir -p .claude
[ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
```

Add the togi marketplace entry if missing:

```bash
jq -e '.extraKnownMarketplaces.togi' .claude/settings.json > /dev/null 2>&1 || \
  jq '.extraKnownMarketplaces.togi = {"source": {"source": "github", "repo": "gwenneg/togi"}, "autoUpdate": true}' \
    .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
```

Enable the plugin if missing:

```bash
jq -e '."enabledPlugins"."togi@togi" == true' .claude/settings.json > /dev/null 2>&1 || \
  jq '."enabledPlugins"."togi@togi" = true' \
    .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
```

Allow friction writes and date lookups without prompting if missing:

```bash
jq -e '.permissions.allow | index("Write(/.claude/friction/**)")' .claude/settings.json > /dev/null 2>&1 || \
  jq '.permissions.allow = ((.permissions.allow // []) + ["Write(/.claude/friction/**)"])' \
    .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json

jq -e '.permissions.allow | index("Bash(date*)")' .claude/settings.json > /dev/null 2>&1 || \
  jq '.permissions.allow = ((.permissions.allow // []) + ["Bash(date*)"])' \
    .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
```

### 2. .gitignore

Append any of the following lines that are not already present in `.gitignore`:

```
/.claude/*
!/.claude/settings.json
```

### Report

After completing all steps, print a summary of what was added vs. already present for each of the two files.

If any step fails, stop and report the error.

## Phase 3: Commit and open a PR

Stage only these files:
- `.claude/settings.json`
- `.gitignore`

Create a branch named `chore/setup-togi` (add `-2`, `-3`, etc. if it already exists).

Commit with message: `chore: set up togi`

Push and open a PR with a body that includes:

- What was configured: togi marketplace entry and plugin enablement in `.claude/settings.json`, and `.gitignore` entries
- How friction capture works: at the end of every turn, the Stop hook prompts Claude to review the turn for friction events (corrections, clarifications, mistakes, denials) and write any that qualify to `.claude/friction/` before stopping — no transcript is sent anywhere, no separate API call is made outside the session. The SessionStart and Stop hooks are part of the togi plugin and fire automatically without any project-side configuration
- Opt-out instruction: run `/togi:disable` at any time (personal, not committed)

Include the standard `Generated with Claude Code` footer.
