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

> **Togi** (研ぎ, to sharpen) is a friction-driven feedback loop for AI context docs. During each session, Claude detects friction events — corrections, clarifications, mistakes, tool denials — and writes them directly to `.claude/friction/` as they occur. Once enough sessions accumulate, a startup reminder prompts the team to run `/togi:update-context-docs`, which turns those events into doc improvements via a pull request.
>
> **Before proceeding, read this carefully:**
>
> **What this installs.** This phase configures your project: it adds the togi marketplace entry and plugin to `.claude/settings.json`, writes the friction capture instructions to `.claude/capture-friction.md`, imports them into `CLAUDE.md`, and updates `.gitignore`. The SessionStart hook that fires `session-start.sh` at each session is managed by the plugin itself via `hooks/hooks.json` — nothing is written to your project for that.

Use `AskUserQuestion` to ask: **"Do you want to proceed with the installation?"** Options: **Yes, proceed** / **No, cancel**.

If the user selects No, stop.

## Phase 2: Configure settings.json, capture-friction.md, CLAUDE.md, and .gitignore

Output the following text verbatim before taking any other action in this phase:

> This phase configures `.claude/settings.json` with the togi marketplace registration and plugin enablement, writes the friction capture instructions to `.claude/capture-friction.md` and imports them into `CLAUDE.md`, and updates `.gitignore` with the togi allowlist. All existing content is preserved.
>
> **Friction capture is enabled by default for everyone on the team.** Events are written as local markdown files to `.claude/friction/` (git-ignored) — no transcript is sent anywhere, no separate API call is made. Any developer can opt out personally with `/togi:disable`, which writes to `.claude/settings.local.json` (not committed).
>
> You can set `TOGI_SESSION_THRESHOLD` (default: `3`) to control how many sessions accumulate before the startup reminder appears.

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

Allow friction writes without prompting if missing:

```bash
jq -e '.permissions.allow | index("Write(.claude/friction/*)")' .claude/settings.json > /dev/null 2>&1 || \
  jq '.permissions.allow = ((.permissions.allow // []) + ["Write(/.claude/friction/**)"])' \
    .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
```

### 2. capture-friction.md

Write `.claude/capture-friction.md` with the following content (skip if the file already exists and is identical):

```markdown
# Togi — Friction Capture

Whenever any of the following occur during a session, write a friction event file **before your next response**. Capture now rather than trying to remember later.

A **friction event** is one of:
- **correction** — you produced something the user had to fix
- **clarification** — the user explained something the docs should have covered
- **mistake** — you made a wrong assumption about the codebase
- **denial** — a tool call was blocked by a permission rule

Before writing a file, apply both filters:
1. Would a concrete rule in a specific project doc have prevented this?
2. Would the same issue likely recur on a similar task?

Skip user errors, one-off scope changes, transient errors, and case-specific corrections.

## How to write a friction file

Write to `.claude/friction/{session_dir}/` where `{session_dir}` is the session directory injected via additional context at session start. If you no longer remember it, read `.claude/friction/active-session` to get the current session directory name.

Use a short kebab-case filename describing the event: `missing-auth-docs.md`, `wrong-test-command.md`.

\`\`\`
---
type: correction|clarification|mistake|denial
doc_gap: <relative path from project root to the target doc file>
date: <YYYY-MM-DD>
---

<One paragraph: what went wrong, what project-specific knowledge was missing,
and the concrete rule or example that would prevent recurrence.>
\`\`\`

Only write to `.claude/friction/` — never elsewhere.
```

### 3. CLAUDE.md

If the line `@.claude/capture-friction.md` is not already present in `CLAUDE.md`, append these two lines to the end of the file:

```
<!-- togi: do not remove the line below — it enables automatic friction capture for this project -->
@.claude/capture-friction.md
```

### 4. .gitignore

Append any of the following lines that are not already present in `.gitignore`:

```
/.claude/*
!/.claude/settings.json
!/.claude/capture-friction.md
```

### Report

After completing all steps, print a summary of what was added vs. already present for each of the four files.

If any step fails, stop and report the error.

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
