---
name: setup
description: Install togi — session hooks that capture AI friction events and remind developers to improve context docs
allowed-tools:
  - Bash(bash setup.sh)
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

> **Togi** (研ぎ, to sharpen) is a friction-driven feedback loop for AI context docs. During each session, Claude detects friction events — corrections, clarifications, mistakes, tool denials — and writes them directly to `.claude/friction/` as they occur. Once enough sessions accumulate, a startup reminder prompts the team to run `/togi:update-context-docs`, which turns those events into doc improvements via a pull request.
>
> **Before proceeding, read this carefully:**
>
> **What this installs.** This phase runs a configure script from the togi plugin to wire up your project: it adds the togi marketplace entry and plugin to `.claude/settings.json`, writes the friction capture instructions to `.claude/capture-friction.md`, imports them into `CLAUDE.md`, and updates `.gitignore`. The SessionStart hook that fires `session-start.sh` at each session is managed by the plugin itself via `hooks/hooks.json` — nothing is written to your project for that.

Use `AskUserQuestion` to ask: **"Do you want to proceed with the installation?"** Options: **Yes, proceed** / **No, cancel**.

If the user selects No, stop.

## Phase 2: Configure hooks, CLAUDE.md, marketplace, and gitignore

Output the following text verbatim before taking any other action in this phase:

> This phase configures `.claude/settings.json` with the togi marketplace registration and plugin enablement, writes the friction capture instructions to `.claude/capture-friction.md` and imports them into `CLAUDE.md`, and updates `.gitignore` with the togi allowlist. All existing content is preserved.
>
> **Friction capture is enabled by default for everyone on the team.** Events are written as local markdown files to `.claude/friction/` (git-ignored) — no transcript is sent anywhere, no separate API call is made. Any developer can opt out personally with `/togi:disable`, which writes to `.claude/settings.local.json` (not committed).
>
> You can set `TOGI_SESSION_THRESHOLD` (default: `3`) to control how many sessions accumulate before the startup reminder appears.

Run:

```bash
bash setup.sh
```

Show the output to the user verbatim. If the command fails, stop and report the error.

## Phase 3: Commit and open a PR

Stage only these files:
- `.claude/capture-friction.md`
- `.claude/settings.json`
- `CLAUDE.md`
- `.gitignore`

Create a branch named `chore/setup-togi` (add `-2`, `-3`, etc. if it already exists).

Commit with message: `chore: set up togi`

Push and open a PR with a body that includes:

- What was configured: togi marketplace entry and plugin enablement in `.claude/settings.json`, friction capture instructions (`.claude/capture-friction.md` imported into `CLAUDE.md`), and `.gitignore` entries
- How friction capture works: during sessions, Claude detects friction events and writes them to `.claude/friction/` as they occur — no end-of-session API call, no transcript sent anywhere. The SessionStart hook is part of the togi plugin and fires automatically without any project-side configuration
- Opt-out instruction: run `/togi:disable` at any time (personal, not committed)

Include the standard `Generated with Claude Code` footer.
