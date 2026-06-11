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

> **Togi** (研ぎ, to sharpen) is a friction-driven feedback loop for AI context docs. At the end of each session, togi resumes the session headlessly to detect friction events — corrections, clarifications, mistakes, tool denials — and writes them to `.claude/friction/`. Once enough friction events accumulate, a startup reminder prompts the team to run `/togi:update-context-docs`, which turns those events into doc improvements via a pull request.
>
> **Before proceeding, read this carefully:**
>
> **What this installs.** This phase configures your project: it adds the togi marketplace entry and plugin to `.claude/settings.json` and updates `.gitignore`. The SessionStart and SessionEnd hooks are managed by the plugin itself via `hooks/hooks.json` — nothing is written to your project for those.
>
> **Cost.** At the end of each session with at least 3 user turns, togi launches a headless `claude -p --resume --fork-session` call to sweep the session for friction events. This is billed to your Anthropic API account (or drawn from your subscription's usage limits). Typical cost: **$0.05–$0.20 per session** when launched promptly (warm prompt cache). Sessions left idle more than 4 minutes before quitting use a Haiku fallback to cap the cold-cache cost. Short sessions (under 3 turns) are skipped entirely.
>
> **Privacy.** The sweep resumes your session via the `claude` CLI on your own account. Your session transcript is not sent to any third party — the sweep runs as a headless Claude Code process under your own credentials, exactly as if you had resumed the session yourself.
>
> Any developer can opt out with `/togi:disable`.

Use `AskUserQuestion` to ask: **"Do you want to proceed with the installation?"** Options: **Yes, proceed** / **No, cancel**.

If the user selects No, stop.

## Phase 2: Configure settings.json and .gitignore

Output the following text verbatim before taking any other action in this phase:

> This phase configures `.claude/settings.json` with the togi marketplace registration and plugin enablement, and updates `.gitignore` with the togi allowlist. All existing content is preserved.
>
> **Friction capture is enabled by default for everyone on the team.** Events are written as local markdown files to `.claude/friction/` (git-ignored). At the end of each qualifying session, the SessionEnd hook launches a headless sweep to review the session for friction and write any qualifying events. Any developer can opt out personally with `/togi:disable`, which writes to `.claude/settings.local.json` (not committed).
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
- How friction capture works: at the end of each qualifying session (≥3 user turns), the SessionEnd hook launches a headless `claude -p --resume --fork-session` sweep to review the session for friction events (corrections, clarifications, mistakes, denials) and write any that qualify to `.claude/friction/`. Typical cost: $0.05–$0.20 per session (warm prompt cache). The SessionStart and SessionEnd hooks are part of the togi plugin and fire automatically without any project-side configuration
- Opt-out instruction: run `/togi:disable` at any time (personal, not committed)

Include the standard `Generated with Claude Code` footer.
