---
name: setup
description: Turn your team's AI friction into better docs — sets up togi with an inert adoption note, a reviewable PR, and per-developer opt-in capture
allowed-tools:
  - Bash(git add *)
  - Bash(git branch *)
  - Bash(git checkout *)
  - Bash(git fetch *)
  - Bash(git rev-parse *)
  - Bash(git remote *)
  - Edit
  - Read
  - Skill(togi:enable)
  - Write
---

# Instructions

If any step in any phase fails, stop and report the error — do not improvise workarounds.

## Phase 1: Explain and get consent

Output the following text verbatim before taking any other action:

> **Togi** (研ぎ, to sharpen) turns AI friction — corrections, clarifications, mistakes, denied tool calls — into context-doc pull requests. For developers who opt in, each ended session is swept for friction events (written as JSON to `.claude/friction/`); once enough accumulate, `/togi:update-context-docs` turns them into a doc PR.
>
> **What this setup commits: nothing executable.** Three inert files — `.gitignore` entries, an adoption note at `.claude/togi.md`, and a pointer in `CONTRIBUTING.md` (or `README.md`). No repo-level marketplace registration or plugin enablement: teammates get togi only by installing it themselves, and capture stays **off for everyone** (`TOGI_ENABLED=0`) until each developer personally opts in — you'll be offered that at the end of this setup.
>
> **Cost, for opted-in developers only.** One headless sweep per session — typically **$0.05–$0.20**, drawn from your own plan limits or API billing. It's cheap because it reuses the session's still-warm prompt cache; sessions left idle until the cache goes cold fall back to Haiku.
>
> **Privacy.** The sweep resumes your session under your own credentials, exactly as if you had resumed it yourself — nothing goes to any third party.
>
> Opt in or out any time with `/togi:enable` / `/togi:disable` — personal, never committed.

Use `AskUserQuestion` to ask: **"Do you want to proceed with the installation?"** Options: **Yes, proceed** / **No, cancel**.

If the user selects No, stop.

## Phase 2: Commit the adoption note and .gitignore entries

Output the following text verbatim before taking any other action in this phase:

> Writing the three inert files now: the `.gitignore` entries, the adoption note `.claude/togi.md`, and the `CONTRIBUTING.md`/`README.md` pointer. Deliberately **nothing** in `.claude/settings.json` — committed marketplace or plugin entries would auto-install togi's hooks onto every teammate's machine; code lands only where its owner installs it.
>
> Teammates who install togi see a **one-time notice** pointing them to `/togi:enable`; until they opt in, nothing runs for them. Tune `TOGI_EVENT_THRESHOLD` (default `5`) to set how many friction events trigger the startup reminder.

### 1. Adoption note

Write `.claude/togi.md` with exactly this content:

```markdown
# This repo uses togi (研ぎ)

[Togi](https://github.com/gwenneg/togi) turns AI friction — corrections, clarifications, mistakes, denied tool calls — into context-doc pull requests. Capture is opt-in per developer and costs ~$0.05–$0.20 per session for those who opt in (their own plan limits or API billing).

To participate, run in Claude Code:

    /plugin marketplace add gwenneg/togi
    /plugin install togi@togi
    /togi:enable

Opt back out any time with /togi:disable. This file is togi's adoption note: it records that this repo adopted togi, and its presence lets togi show a one-time opt-in notice to developers who already have the plugin installed — nothing in this repo installs or runs anything by itself.
```

### 2. Contributor docs pointer

If `CONTRIBUTING.md` exists, append the following section to it; otherwise append it to `README.md`:

```markdown
## AI friction capture (togi)

This repo uses [togi](https://github.com/gwenneg/togi) to turn AI friction into context-doc improvements. Participation is opt-in per developer — see [.claude/togi.md](.claude/togi.md) for the setup commands and cost model.
```

### 3. .gitignore

Append any of the following lines that are not already present in `.gitignore`. Ignore only what togi creates — do not ignore `.claude/` wholesale, which would hide files teams commit deliberately (commands, agents, skills):

```
/.claude/friction/
/.claude/settings.local.json
/.claude/togi.log
/.claude/togi-notice-shown
```

### Report

After completing all steps, print a summary of what was added vs. already present for each file touched: `.gitignore`, `.claude/togi.md`, and the `CONTRIBUTING.md`/`README.md` pointer.

## Phase 3: Offer to enable capture for this developer

Capture is dormant until each developer opts in. Use `AskUserQuestion` to ask: **"Enable friction capture for yourself now?"** Options: **This repo only** / **All my repos** / **Not now**.

- **This repo only** — invoke the `/togi:enable` skill with the argument `repo`.
- **All my repos** — invoke the `/togi:enable` skill with the argument `all`.
- **Not now** — skip; mention that `/togi:enable` works at any time.

The enable skill owns the opt-in commands and confirmation outputs — do not inline or restate them here.

## Phase 4: Commit and open a PR

1. Pick the base remote: `upstream` if it exists (fork workflow — `origin` is the fork and may be stale), otherwise `origin`. Call it `<remote>` below. Then detect the default branch:
   - `git rev-parse --abbrev-ref <remote>/HEAD` → strip the `<remote>/` prefix yourself.
   - If unset (common for upstream remotes and manually-cloned repos): `git remote show <remote>` → read its `HEAD branch:` line.
   - If both fail, use `main`.
2. Pick a unique branch name: `chore/setup-togi`, appending `-2`, `-3`, … if `git branch --list` shows it taken.
3. Branch from the up-to-date default — never from the current HEAD, which may carry unrelated work. The Phase 2 changes are uncommitted and carry over:

   ```bash
   git fetch <remote>
   git checkout -b chore/setup-togi <remote>/<default-branch>
   ```

4. Stage exactly the three Phase 2 files — `.gitignore`, `.claude/togi.md`, and the pointer file — then commit with message: `chore: set up togi`
5. Push the branch to `origin` (on a fork that is your fork; `gh pr create` then targets the upstream repo automatically), and open a PR titled `Set up togi` with this body (adjust the pointer filename; append the standard `Generated with Claude Code` footer):

   ```markdown
   Sets up [togi](https://github.com/gwenneg/togi). Every time Claude stumbles in this repo — a wrong assumption, a missing convention, a denied command — that's a gap in our context docs. Togi captures those moments and turns them into doc PRs, so the same stumble doesn't happen twice.

   **Is this safe to merge?** Yes — and you can verify it from the diff alone. The entire change is three inert text files: `.gitignore` entries, the adoption note `.claude/togi.md`, and a pointer in `CONTRIBUTING.md`. No settings, no hooks, no code: merging installs nothing and runs nothing on anyone's machine. If the diff shows anything beyond those three files, reject this PR.

   **Trying it costs a minute and pennies.** Run the three commands in `.claude/togi.md`, work normally, and check `.claude/friction/` after a few sessions. Capture is opt-in per developer: a headless sweep — Claude resuming your ended session under your own credentials, nothing sent to any third party — reviews each session for friction events. Typical cost: $0.05–$0.20 per session, on your own plan limits or API billing. Haven't opted in? You'll see a one-time notice and nothing else will ever run. Leave any time with `/togi:disable`.
   ```
