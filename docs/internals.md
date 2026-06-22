# Togi internals & deep reference

This document is the deep-dive companion to the [README](../README.md). The README is the high-altitude on-ramp; everything here is for someone who wants the *why* behind a specific topic — the cost model, the security posture, the release process, the rejected alternatives.

## Contents

1. [Architecture & lifecycle](#1-architecture--lifecycle)
2. [Friction capture: alternatives considered](#2-friction-capture-alternatives-considered)
3. [Cost model](#3-cost-model)
4. [Privacy & security](#4-privacy--security)
5. [Activation & opt-in](#5-activation--opt-in)
6. [Team adoption & distribution](#6-team-adoption--distribution)
7. [Processing friction into docs](#7-processing-friction-into-docs)
8. [Supply chain & releases](#8-supply-chain--releases)
9. [Future work](#9-future-work)
10. [Verified empirical facts](#10-verified-empirical-facts)

Appendix — [Claude Code & API documentation](#claude-code--api-documentation)

---

## 1. Architecture & lifecycle

Capture happens **in-session**: a directive injected by the `SessionStart` hook tells the working model to record friction as it works, and two more hooks support it. Plus the processing skill (see the [hooks reference](https://code.claude.com/docs/en/hooks) and [hooks guide](https://code.claude.com/docs/en/hooks-guide) for the hook mechanism):

- **Capture directive** (`assets/prompts/session-start.md`, shipped in the plugin) — injected into context by the `SessionStart` hook for enabled developers; it instructs the model, when it hits a correction (a knowably-wrong choice) or a clarification (a missing fact) — including an error it catches itself — to write a one-event markdown file under `.togi/friction/pending/`. The directive is **never imported or committed** — the gated hook is its only delivery channel, so it reaches the model exactly when capture is enabled (the import-based delivery this replaced is [alternative #10](alternatives/10-directive-delivery-via-import.md)).
- **`Stop` hook** (`scripts/stop.sh`) — fires every turn and increments a per-session turn counter; when the counter reaches `TOGI_REMINDER_INTERVAL` (default 10) it re-injects a short salience reminder (via `additionalContext`) and resets the counter. `SessionStart` resets the counter on every session event (startup, resume, clear, compact), so the interval is always relative to the most recent directive delivery.
- **`PermissionDenied` hook** (`scripts/permission-denied.sh`) — records each denied tool call as a `denial` event file directly, with no model call.
- **`SessionStart` hook** (`scripts/session-start.sh`) — counts pending friction events; once the count reaches `TOGI_EVENT_THRESHOLD`, it injects a reminder to process them (`SessionStart` stdout is added to context per the [hooks reference](https://code.claude.com/docs/en/hooks)). In repos that adopted togi but where the developer hasn't opted in, it shows a single opt-in notice instead.
- **`/togi:update-context-docs` [skill](https://code.claude.com/docs/en/skills)** — groups accumulated events by root cause, decides which docs to fix, edits them, opens a PR, and archives the processed events.

The full loop:

```
you work → model hits friction → writes a note to .togi/friction/pending/   (denials: PermissionDenied hook)
                                                  ↓
               Stop hook keeps the capture directive salient as context grows
                                                  ↓
          next session start → session-start.sh → "12 friction events. Update the docs."
                                                  ↓
          developer runs /togi:update-context-docs → docs edited → PR opened
                                                  ↓
          PR merged → agent reads better docs → fewer stumbles next session
```

All hooks are gated on `TOGI_ENABLED=1` and exit immediately otherwise, so a developer who hasn't opted in never receives the directive at all. Capture is the working model's choice (the directive is context, not enforcement), so recall is real but unmeasurable — see [§2](#2-friction-capture-alternatives-considered) for the trade against the retired sweep.

### Keeping the directive salient

The `SessionStart` hook delivers the directive fresh each session, but the model's attention is dominated by recent context — research on transformer attention distribution ([Liu et al., 2023, *Lost in the Middle*](https://arxiv.org/abs/2307.03172); [confirmed on 18 frontier models including Claude Opus 4 and GPT-4.1 by Chroma Research, 2025](https://www.morphllm.com/context-rot)) shows a U-shaped curve: attention is highest at the beginning and end of the context window and degrades significantly in the middle. The directive is always at the beginning (primacy zone) and doesn't drift, but as the session grows, the model's working attention is increasingly anchored to recent content — the current user message, recent tool outputs, recent code. A directive from many turns ago competes against a dense block of recency-weighted context.

Compaction is handled separately: `SessionStart` with no matcher (so `source: "compact"` is included) re-delivers the full directive before the first post-compaction model response (live-verified — §10).

For long sessions without compaction, the `Stop` hook counters recency dominance with a **turn-count-based reminder**: it maintains a per-session counter in a temp file (`$TMPDIR/togi-refresh-<session_id>`) and increments it every turn. When the counter reaches `TOGI_REMINDER_INTERVAL` (default 10, configurable — §5) it re-injects a one-line reminder via `hookSpecificOutput.additionalContext` — injected as a `<system-reminder>` at the recency end of context, where attention is highest, and visible in the terminal but not as a chat message — then resets the counter. `SessionStart` resets the counter to 0 on every session event (startup, resume, clear, compact), so the interval is always relative to the most recent directive delivery; no compaction detection is needed in `Stop`.

Token growth was an earlier proxy for the same concern but is a weaker signal than turn count: a turn that generates 8k tokens of context and a turn that generates 500 tokens both advance the session by one turn, and the recency effect is about conversational distance, not byte count. The reminder goes through `hookSpecificOutput.additionalContext`, which injects into Claude's context as a `<system-reminder>`; plain stdout from `Stop` goes to the debug log only and is never seen by Claude.

### Capturing denials

Denials are the one friction type a hook captures more reliably than the model. The `PermissionDenied` hook writes a `denial` event file named by a stable slug (`denied-<tool>-<cksum>`, so an identical recurring denial dedups to one file). It records the tool and a truncated input factually; turning that into a doc rule happens later, in the skill. Precision is lower than the semantic types — it also catches legitimate user vetoes — but the skill's noise-exclusion handles those at processing time.

### Friction file shape

**One markdown file per event** under `.togi/friction/pending/`, named by a kebab-case slug of the root cause (so recurring friction with the same cause dedups to one file):

```markdown
# <type>

<one paragraph: the friction AND the rule that would prevent recurrence>

**Misleading doc:** <path>   <!-- optional -->
```

- `type` — the `# ` heading: `correction`, `clarification`, or `denial`; drives the PR metrics breakdown. (`correction` = a knowably-wrong choice → the docs need a louder rule; `clarification` = a missing fact → the docs need to supply it. A self-caught error folds into whichever fix it implies. `denial` is hook-written.)
- `body` — the paragraph: drives grouping, placement, the recurrence match, and the edit.
- `misleading_doc` (optional) — a high-confidence placement hint (see [§7](#7-processing-friction-into-docs)).
- `date` — the file's modification time; no date is written into the file.

Markdown (not JSON) because the model writes these inline — one short prose file is trivial to produce, with no JSON validity to get right — and the consumer (`/togi:update-context-docs`) is an LLM skill that reads markdown naturally. The session-start counter is just the number of `.md` files in `pending/`.

---

## 2. Friction capture: alternatives considered

The core problem: detect friction events (corrections, clarifications, tool denials) reliably, without taxing the session, at acceptable cost, with an honest privacy story. The current approach — **in-session inline capture** (a friction directive refreshed by a context-aware `Stop` hook, plus a `PermissionDenied` hook for denials) — is described in [§1](#1-architecture--lifecycle). It was reached after weighing nine approaches; the table records how they trade off.

| # | Approach | Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|---|---|
| 1 | [CLAUDE.md import, per-message instructions](alternatives/01-claude-md-import.md) | Low, unmeasurable | Invisible, but per-message attention tax | ~free | No | Minimal |
| 2 | [Unconditional blocking Stop hook](alternatives/02-unconditional-blocking-stop-hook.md) | Medium | **Prompt wall every turn** | ~$1+ (extra inference/turn) | No | Low |
| 3 | [Conditional Stop hook (keyword grep on transcript)](alternatives/03-conditional-stop-hook.md) | Medium, keyword-blind | Occasional visible block | Low | No | Medium |
| 4 | [`UserPromptSubmit` silent `additionalContext`](alternatives/04-userpromptsubmit-injection.md) | Low (advisory only) | Invisible | ~free | No | Low |
| 5 | [Layered: hook-parsed denials + keyword fast path + once-per-session sweep](alternatives/05-layered-capture.md) | High | One visible block/session | Low | No | High |
| 6 | [Per-turn Haiku classifier in Stop hook](alternatives/06-per-turn-haiku-classifier.md) | High | Invisible, +latency every turn end | Medium | Yes, per turn | Medium |
| 7 | [SessionEnd → headless `claude -p` over transcript (fresh context)](alternatives/07-fresh-context-transcript-sweep.md) | High | Invisible | Medium (full re-read, no cache) | Yes, per session | Medium |
| 8 | [SessionEnd digest → sweep at next SessionStart](alternatives/08-deferred-sweep-at-sessionstart.md) | Medium-high | Work at top of next session | Low | No | Medium |
| 9 | [SessionEnd → `claude -p --resume --fork-session` sweep](alternatives/09-session-end-resume-sweep.md) | High | Invisible | ~$0.05–0.20 (warm cache) | Yes, per session | Medium |

Each approach above has a standalone write-up under [`alternatives/`](alternatives/) — what it is, why it wasn't taken (or, for #9, why it was retired), and a plan to implement it if revisited. Approach 9 was togi's original implementation, replaced by inline capture. A further file, [alternative #10](alternatives/10-directive-delivery-via-import.md), records a separate *delivery-channel* decision within the chosen approach — why the directive is injected by the `SessionStart` hook rather than imported from a `CLAUDE.md`-family file (committed `CLAUDE.md`, `CLAUDE.local.md`, or `~/.claude/CLAUDE.md`).

### Why inline capture

Inline capture is ~free (no extra API call), nearly invisible, and portable — it rides the working session instead of a detached headless process. The sweep (#9) had higher, *measurable* recall and full-session hindsight, but its per-session billing, detached-process fragility, and reliance on session resume/fork (and, for subscription users, an Agent SDK credit that doesn't port to other agents) outweighed that once native auto memory began covering the durable-facts slice for free. The trade accepted: inline capture's recall is lower and unmeasurable — mitigated by the `Stop`-refresh keeping the directive salient, and a `PermissionDenied` hook capturing denials deterministically.

---

## 3. Cost model

**Effectively free.** Capture rides the working session — the model writes a short markdown note (a few hundred tokens) when it hits friction, and the `PermissionDenied` hook records denials with no model at all. There is no separate API call, no headless run, no per-session billing. An installed-but-unenabled plugin does nothing; an enabled one adds only the negligible cost of the occasional note-writing turn plus the `Stop`-refresh's silent reminder.

This replaces togi's original **end-of-session sweep**, which billed ~$0.05–0.20 per session against the Agent SDK credit — with warm-cache economics, a Haiku cold-fallback, telemetry, and ambient-`ANTHROPIC_API_KEY` billing surprises. That entire cost model, and the reasons it was retired, now lives in [alternative #9](alternatives/09-session-end-resume-sweep.md).

---

## 4. Privacy & security

### Privacy posture

Nothing leaves your machine. Capture happens inside your own session under your own credentials; friction notes are written locally under `.togi/friction/` (`pending/`, then `archive/` once processed — both git-ignored), and nothing is sent to any third party. The capture directive (`assets/prompts/session-start.md`, shipped in the plugin) is plain, reviewable instructions, and denied tool calls are recorded by the `PermissionDenied` hook with no model in the loop. Any developer can opt out with `/togi:disable`.

Capture writes are visible `Write` tool calls — the model jots the note in your session. To keep them from prompting mid-session, add a `permissions.allow` rule such as `Write(.togi/friction/**)`, honored because `.togi/` is not a [protected path](https://code.claude.com/docs/en/permission-modes#protected-paths).

### Injection guardrail at processing time

Friction notes derive from session content and are therefore injectable — not trusted input for anything beyond doc prose. The real exposure is the **processing** step: `update-context-docs` reads notes and opens a PR, so a note crafted to smuggle exfiltrated content (a secret read into a `body`) could ride into that PR. Two guardrails contain it: the capture directive tells the model to summarize friction in a short note, not to copy file contents; and the skill's edit targets must be **in-repo documentation files** — never settings, code, CI, or hook files — regardless of what a note's `body` or `misleading_doc` names. Every event is also surfaced for user review before any edit.

### Protected paths vs. skill permissions (docs-sourced, NOT live-verified)

`.claude` is on Claude Code's fixed [protected-directories list](https://code.claude.com/docs/en/permission-modes#protected-paths). Writes to protected paths are **never auto-approved** in any mode except `bypassPermissions`, and the check runs **before** allow rules are evaluated — so neither `permissions.allow` in settings nor a skill's `allowed-tools` can pre-approve a write to `.claude/settings.json` or `.claude/settings.local.json` (the two are treated identically). Rationale: settings define permissions, so nothing running under the permission system may rewrite them silently.

Consequences for togi:

- The settings writes in `/togi:enable`, `/togi:disable`, and `/togi:setup` **always prompt**. Acceptable — the write toggles a consent flag, and the prompt puts that approval in front of exactly the right person at the right moment.
- `disable` carries **no `allowed-tools`**: its whole job is the protected settings write, which prompts regardless, so an allowlist buys nothing. `enable` allowlists only its non-protected helper commands — `Bash(command -v jq)` (the jq check) and `Bash(mkdir -p .togi/friction/pending)` (creating the capture directory, which lives outside protected `.claude/`) — so those run promptless; its settings write still prompts like `disable`'s.
- `setup` keeps `allowed-tools` only for steps pre-approval can actually serve: `Write`/`Read`/`Edit` for the files it commits (`.gitignore`, the CONTRIBUTING/README pointer, and the adoption note `adopt-togi.md` — all outside Claude Code's protected `.claude/`, so the grant actually pre-approves them), and the git/gh flow. (Moving the adoption note out of `.claude/` is what made it pre-approvable; under `.claude/` it was protected and prompted regardless.) Everything else was removed: `Bash(mkdir*)`, `Bash(touch .claude/*)`, `Bash(mv .claude/*)`, later `Bash(jq*)` and `Bash(grep*)`. A dead grant is worse than a prompt.
- Whether the check inspects Bash redirect targets (`> .claude/foo.tmp`) or `mv` side effects is undocumented. Togi deliberately does **not** rely on that either way — routing writes through a vehicle the checker might miss would be evading a safety feature via an undocumented gap.
- `setup` Phase 3 delegates the opt-in to the `enable` skill via the `Skill` tool (`Skill(togi:enable)` in allowed-tools; `enable` accepts `repo`/`all` to skip its scope question), so the opt-in commands live in exactly one file. Docs-sourced ([skills](https://code.claude.com/docs/en/skills), [tools reference](https://code.claude.com/docs/en/tools-reference)): the Skill tool "executes a skill within the main conversation" and `Skill(name)` is the documented permission syntax — but skill-from-skill nesting is NOT explicitly documented. Verify on the first live setup run.

---

## 5. Activation & opt-in

`TOGI_ENABLED` defaults to **`0`** (opt-in per developer): an installed plugin is dormant — hooks exit immediately, no directive injected, no capture, no files. It is read from the settings `env` block ([Claude Code settings](https://code.claude.com/docs/en/settings)). Each developer opts in personally via `/togi:setup` (offered at the end) or `/togi:enable`, at one of two scopes, both uncommitted:

- **repo**: `env.TOGI_ENABLED = "1"` in `.claude/settings.local.json` — this repo only
- **global**: same key in `~/.claude/settings.json` — every repo for this user

**Why opt-in.** `/plugin marketplace add` registers user-globally (`~/.claude/plugins/known_marketplaces.json` — there is no project-scoped form), and `/plugin install` defaults to **user scope** ([discover & install plugins](https://code.claude.com/docs/en/discover-plugins)), so the hooks fire in every repo on the machine. Enabling by default would therefore have meant capturing in every repo on the machine and writing `.togi/friction/` files into repos whose `.gitignore` was never configured — an accidental-commit/leak hazard. Opt-in also makes install scope irrelevant: a user-scope install is safe because it is dormant everywhere the developer hasn't enabled it.

### Precedence

A repo-local `TOGI_ENABLED=0` overrides a global `1` — settings precedence is local > project > user, below command-line args and managed settings ([settings precedence](https://code.claude.com/docs/en/settings), docs-sourced, NOT live-verified) — which is what keeps `/togi:disable` meaningful for global opt-ins. The same precedence cuts the other way: a global `0` does **not** override repo-local `1`s, so repos opted in individually must be disabled individually. The disable skill's global output states this exception instead of over-promising.

### One-time opt-in notice

In repos carrying the committed adoption note `adopt-togi.md` (see [§6](#6-team-adoption--distribution)), `SessionStart` shows not-yet-opted-in developers a single notice (cost + `/togi:enable`) and drops a marker at `.togi/togi-notice-shown` (git-ignored by setup) so it never repeats. Repos without the adoption note stay completely silent — that is the guard against user-scope installs nagging in unrelated projects.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `0` | The only switch, **off by default**. `1` activates the capture hooks (the `Stop`-refresh and the `PermissionDenied` recorder). A repo-local `0` overrides a global `1`. |
| `TOGI_EVENT_THRESHOLD` | `10` | Friction events accumulated before the startup reminder appears. See the threshold rationale in [§7](#7-processing-friction-into-docs). |
| `TOGI_REMINDER_INTERVAL` | `10` | Turns between salience reminders from the `Stop` hook. Lower if friction recall feels low in medium-length sessions; raise to reduce reminder frequency in very long ones. See [§1](#1-architecture--lifecycle) for the research rationale behind turn count as the signal. |
| `TOGI_DEBUG` | `0` | `1` writes structured hook logs to `.togi/togi.log` in the project directory. |

### Rejected, do not reintroduce

- `TOGI_SWEEP_ENABLED` as a *committed project-level* consent flag — consent stays personal and uncommitted.
- `TOGI_MIN_TURNS` (skip capture for sessions below a turn threshold) — tried and removed; stays out.

---

## 6. Team adoption & distribution

`/togi:setup` commits **nothing executable**: no `extraKnownMarketplaces`, no `enabledPlugins`, no marketplace registration, no plugin enablement.

Committed marketplace/plugin entries are the platform's documented team pattern ("Require marketplaces for your team" — see [plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces) and [Claude Code settings](https://code.claude.com/docs/en/settings)), and teammates do get a prompt at folder-trust — but the prompt's decline behavior is undocumented, hooks get no separate trust step, and even "dormant" hooks execute at every session boundary. Committing enablement would grant togi's author code execution on every teammate's machine *on their behalf*, which contradicts togi's own supply-chain posture: code lands on a machine only when its owner installed it.

Instead the repo carries an **adoption note**: `adopt-togi.md` (install commands; inert) plus a pointer section in `CONTRIBUTING.md`/`README.md`, with the setup PR as the team's review artifact. The adoption note doubles as the signal for the one-time opt-in notice ([§5](#5-activation--opt-in)).

`/togi:setup` commits three inert files (the capture directive is **not** among them — it ships in the plugin and is delivered only by the gated `SessionStart` hook; see [alternative #10](alternatives/10-directive-delivery-via-import.md) for why it isn't committed/imported):

1. `adopt-togi.md` — the adoption note (install commands)
2. a pointer section in `CONTRIBUTING.md` (or `README.md`)
3. `.gitignore` entries — `/.togi/` and `/.claude/settings.local.json` (never `.claude/` wholesale, which would hide files teams commit deliberately)

Each developer then installs togi deliberately (the two `/plugin` commands, then `/togi:enable`). Developers who already have the plugin get a one-time notice in adopted repos pointing them to `/togi:enable`; beyond that, nothing runs on their account without their say-so.

**Trade-off accepted:** adoption is three manual commands per developer instead of zero, and developers who never install the plugin see no in-product discovery at all — the pointer section carries that load.

---

## 7. Processing friction into docs

`/togi:update-context-docs` is the interactive stage that turns accumulated events into a doc PR. The skill file (`skills/update-context-docs/SKILL.md`) is the procedure; this section is the rationale behind its design choices.

### Doc targeting happens here, not at capture time

Capture writes a lightweight note; it does **not** name the doc to fix. `update-context-docs` decides placement, with the user in the loop. Why defer it: at capture time the model is mid-task, and a friction event exists precisely because the relevant knowledge was *not* in context — so a doc the model named would usually be a guess, and a guessed path that doesn't exist is an event silently dropped at edit time. Capture-time targeting also fragments aggregation: two sessions naming different docs for one root cause look unrelated.

The split follows what each stage can do well:

- **Capture records what only it knows** — the friction itself, in a one-paragraph `body`, plus an optional `misleading_doc` when a doc that *was* in context gave wrong guidance (the one case where in-the-moment doc identification is reliable and hard to reconstruct later from the `body`).
- **`update-context-docs` decides placement** — it has repo visibility (the actual, current doc tree, not capture-time paths that go stale), all events across sessions (root-cause grouping: one fix may serve many events, one event may need several docs, a new doc may be warranted), and the user reviewing proposed targets before any edit. It costs nothing extra — the skill already reads every target before editing.
- **Injection guardrail:** targets must be in-repo documentation files — never settings, code, CI, or hook files ([§4](#4-privacy--security)).

### Keeping the pile signal-rich

The capture directive carries two filters and a selectivity rule, inherited from the retired sweep prompt: record an event only if **(1)** a concrete rule in a project doc would have prevented it **and (2)** the same issue would likely recur — skipping one-off scope changes, transient errors, slips immediately fixed, and case-specific corrections, and capturing sparingly (a flood of marginal events erodes the reminder's credibility). The sweep enforced these over a whole-session batch plus a hard cap of five; inline capture applies them per moment as a "be selective" instruction, with slug-dedup collapsing a recurring root cause to one file. There is no separate schema gate: events are plain markdown the processing skill reads directly (the retired JSON sweep needed a jq gate; markdown does not). The body is also directed to **name the subsystem/workflow/convention precisely**, since it is the only signal Phase 2 has for choosing the target doc.

The reminder threshold (default `TOGI_EVENT_THRESHOLD` = 10) is a *batch size* — how many accumulated events warrant asking the developer to process them. Too low and one productive session trips a thin PR that gives root-cause grouping nothing to work with; ~10 spans a few sessions so grouping has material, while staying low enough that friction does not rot (a stale gap keeps the agent stumbling). A single high-friction session loses nothing: its events persist and trip the reminder a session later. Going much above ~15 makes the feedback loop sluggish.

### Feedback loop: processed-event archive + recurrence detection

Togi's promise is "PR merged → agent reads better docs → fewer stumbles", but nothing ever verified the last arrow — and the cleanup phase actively destroyed the data needed to check, `rm`-ing friction files after processing. A gap recurring *after* its fix landed is the most valuable signal in the system (the rule is too weak, lives in a doc agents don't read, or the PR never merged) and was indistinguishable from a brand-new event.

Now `update-context-docs` **archives instead of deletes**: one markdown file per processed event under `.togi/friction/archive/` (excluded ones included), each carrying its original body plus a `**Processed:**` annotation line — the processed date, the `outcome` (`doc_updated`/`excluded`), and the target doc(s). Before editing, the skill compares incoming event groups against the archive — semantically, by `body` text (free-form prose, so compare meaning, not strings) — and flags:

- **Recurrence after fix** (`doc_updated`, event `date` > `processed_date`): the fix didn't take. Severity floor: medium; strengthen or relocate the previous rule instead of appending a near-duplicate. Caveat the skill is told about: a recurrence may just mean the fix PR hasn't merged yet.
- **Recurrence after exclusion**: previously dismissed as noise and came back — surfaced to the user as "probably real after all".

Design constraints honored:

- Pending and archived events live in sibling directories — `.togi/friction/pending/` (written in-session, counted by the session-start reminder) and `.togi/friction/archive/` (written at processing, read only by the recurrence check) — so every consumer reads exactly the directory it means; no depth-limiting convention for a scan to forget.
- `.gitignore`'s `/.togi/friction/` covers both directories: local history, never committed (same privacy posture as pending events).
- The archive write is a `Write` into protected `.claude` and prompts once per run — accepted, not routed around ([§4](#4-privacy--security)).
- Archive files older than ~2 months are pruned at cleanup. The window only needs to cover PR-merge lag plus a few sessions on the fixed docs — recurrence slower than that is indistinguishable from new friction — and the whole archive enters the skill's context every run, so retention is a context-bloat knob, not just disk hygiene.

Trade-off accepted: excluded events are no longer "acceptable losses" — they persist in the archive as history. That is the point: exclusion was a judgment, and the archive is what lets a wrong judgment be caught.

---

## 8. Supply chain & releases

A Claude Code plugin is not a passive dependency — installing it grants the author a **standing right to execute code on every user's machine**, at every session start and end, with no per-update review (Claude Code shows no diff and asks for no re-approval when plugin hooks change). Claude Code also has **no plugin signing, checksum, or integrity-verification step** in its install path. So the security bar for publishing togi is closer to *running a software-update service* than *shipping a library*. The publishing flow below is built around that fact.

### The model: two layers, each deliberately gated

Distribution has two independent layers, and with the choices togi makes, neither tracks "latest" automatically:

1. **The marketplace catalog** ([`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json), see [creating a marketplace](https://code.claude.com/docs/en/plugin-marketplaces)) — fetched from `main` when a user adds the marketplace, and refreshed **only** when they explicitly run `/plugin marketplace update`. **Auto-update is off** (Claude Code's default for third-party marketplaces, which togi never overrides — see [discover & install plugins](https://code.claude.com/docs/en/discover-plugins)), so nothing refreshes it at startup.
2. **The plugin code** — the catalog pins the plugin `source` to a **full commit `sha`** (a plugin source supports both `ref` and `sha`, per the [marketplace reference](https://code.claude.com/docs/en/plugin-marketplaces)):
   ```json
   "source": { "source": "github", "repo": "gwenneg/togi", "ref": "vX.Y.Z", "sha": "<40-char commit>" }
   ```
   Installing or updating togi fetches the plugin from that exact commit, not from `main`. Each release commit also carries a human-readable tag (e.g. `vX.Y.Z`) for reference, but the pin resolves the SHA, not the tag. A relative `"./."` source would instead track whatever ref the catalog was fetched at (effectively `main`) — the explicit `github` + `sha` source is what decouples the code users run from `main`.

The consequence: **work-in-progress on `main` never reaches users.** A new version reaches them only when (a) the SHA pin is deliberately bumped *and* (b) they choose to refresh the catalog and update the plugin.

### Why this design (and why it's the strongest posture available)

The goal is three properties, in priority order:

- **No silent execution.** Auto-update would push whatever is on `main` to every user automatically — an un-recallable channel where a single bad commit (or a compromised account) becomes instant, unsupervised code execution everywhere. Turning auto-update off removes that channel: updates require a human decision on the user's side.
- **Tamper-evidence / verifiability.** Pinning to a commit `sha` rather than a branch or a tag means git's content-addressing fixes the exact bytes users run. A branch (`"./."`, the default) ships every commit; a tag (`ref`) can be force-moved; a **SHA cannot be moved or re-pointed**. Anyone can verify what they run by comparing the pinned SHA in `marketplace.json` against the repository history and inspecting the tree at that commit. This is the strongest integrity guarantee obtainable in a model where the consumer git-fetches source and the platform offers no signing.
- **Deliberate, reviewable releases.** Because the SHA bump is an explicit commit to `main`, every release is a single, auditable change rather than an implicit side effect of pushing code.

Given the platform's constraints (no plugin signing, hooks trusted implicitly, source fetched directly from git), **SHA-pin + auto-update-off is the most secure configuration available**: it strictly dominates the alternatives — a relative `"./."` source (tracks `main`, ships everything), a `ref`/tag pin (mutable), or auto-update on (silent) — on every one of the three properties above.

### `version` in the marketplace entry, not in `plugin.json`

`version` is Claude Code's **update cache key** (resolution order: `plugin.json` `version` → marketplace entry `version` → source commit SHA — see the [plugins reference](https://code.claude.com/docs/en/plugins-reference)). Togi sets `version` in the **marketplace entry** only — never in `plugin.json`. Two reasons, one per file:

- **`plugin.json` omits `version`** because `plugin.json` is priority #1 in the resolution order. If it set a version, that string would silently win over the marketplace entry value, so bumping the marketplace entry alone would not trigger updates — a drift footgun where a version bump in the wrong file ships nothing.
- **The marketplace entry sets `version`** so users see a human-readable string (e.g. `0.2.1`) in `claude plugin list` instead of a raw commit SHA. The SHA remains the security pin; the version string is the cache key. Both must change together on every release — the release workflow enforces this atomically: one PR updates `version`, `ref`, and `sha` in `marketplace.json` in lockstep.

### Honest residual risks

This posture is not a complete defense, and the gaps point to complementary controls:

- **The pin lives on `main`.** Anyone who can write to `main` — via a compromised account or a merged malicious PR — can rewrite the SHA. Pinning gives deliberate releases and verifiability, **not** protection of `main` itself. That requires account hardening (hardware 2FA, no long-lived tokens), branch protection with required reviews and status checks, and signed commits/tags.
- **The catalog is an unpinned branch fetch.** When a user refreshes the catalog they pull `main`'s *current* `marketplace.json`, so a rewritten SHA is picked up on their next refresh. This is inherent to the catalog being the update channel; signed + protected `v*` tags and the SHA pin reduce, but do not eliminate, the exposure.
- **No update notifications.** Claude Code does not tell users when a new version exists.

### Cutting a release

Releases are deliberate — pushing to `main` does **not** ship code to users. Content commits land on `main` as usual; CI then automates the release plumbing:

1. **CI opens a release PR** — on every non-release push to `main`, `.github/workflows/prepare-release.yml` infers the semver bump from conventional commit prefixes (`feat:` → minor, a `!` before the colon → major, everything else → patch), then opens or updates a PR that bumps `version`, `ref`, and `sha` in `.claude-plugin/marketplace.json` atomically. The pinned `sha` is the content commit the PR was generated from.
2. **Review and merge** — the PR is the review artifact. Merging is the only manual step. Squash-merge it, so the release commit's subject keeps the `release:` prefix the next workflow keys on.
3. **CI tags and publishes the release** — `.github/workflows/create-release.yml` detects the release commit (message starts with `release:`), reads `source.sha` back out of the merged `marketplace.json`, and runs `gh release create vX.Y.Z --generate-notes --target <source.sha>`. That creates the git tag and the GitHub Release in one step, and tags the exact content commit the catalog pins — so `ref` and `sha` resolve to the same commit, and users get a discovery signal plus a changelog.

The triple update (`version` + `ref` + `sha`) is the release: the version string changes the plugin's identity so Claude Code detects an update; the SHA fixes the exact, immutable bytes users run; the ref is the human-readable tag for audits, pointing at the same commit the SHA pins.

> **Verified (prior design — re-verify with version field):** a pinned-SHA bump delivers updates. With `version` omitted, the plugin identity fell back to the source commit SHA; bumping the pin (`241c78b` → `41e0a31`) then running `/plugin marketplace update` + `/plugin update togi@togi` moved an installed client to the new commit and ran the new hook code (the new telemetry stamps appeared in its output). With `version` now set in the marketplace entry, the identity is the version string — the update flow needs re-verification with the new design. A live `/plugin install` of a pinned `sha` source resolved as documented — still expected to hold.

### Staying up to date

Because auto-update is off, Claude Code gives **no proactive notification** when a new version exists — so to find out, **watch this repository → Releases only** on GitHub. When a release is published, update in two steps (see [discover & install plugins](https://code.claude.com/docs/en/discover-plugins)):

```
/plugin marketplace update      # 1. refresh your local catalog from main — picks up the new pinned SHA
/plugin update togi@togi        # 2. install the plugin at that SHA
```

Step 1 is required: until you refresh the catalog, Claude Code has no knowledge that a newer release exists. Step 2 then installs the plugin at the commit the refreshed catalog pins. If Claude Code prompts you to reload afterward, run `/reload-plugins`.

---

## 9. Future work

### Remote friction pooling + CI processing (deferred, not designed)

Idea: instead of accumulating friction on each dev's machine, push events to a remote branch and have a CI job process them. Recorded for a later stage; nothing below is committed to.

It decomposes into two proposals with very different profiles — most of the benefit lives in the first, most of the cost in the second:

**(a) Pooling events remotely.** The strongest argument for togi-anything: the capture filter is "would this recur?", and the best evidence of recurrence is the same root cause hitting several developers — a signal that per-machine accumulation makes structurally invisible. Today three devs each sit at 2 events, nobody crosses the threshold (or worse, three PRs open for the same gap). Cross-dev pooling would make aggregation-time root-cause grouping work over the team's events, not one person's. It also stops friction rotting on machines of devs who ignore the reminder, survives laptop wipes, and serves multi-machine devs. Mechanically cheap: a dedicated ref/branch, one uniquely-named file per session, no merge conflicts.

**(b) Processing in CI.** Buys timeliness (no human has to remember), but conflicts with three load-bearing commitments:

- **Privacy.** Event `body` paragraphs are distilled session content; the current story is "nothing leaves your machine except your own API call". Pushing raw events publishes session-derived prose to everyone with repo read access — and bodies are already classified as an exfiltration channel ([§4](#4-privacy--security)). Auto-pushing at session end removes the *first* human gate (Phase 3 event review) at the most sensitive point. Sanitization cannot fix this: the body *is* the payload.
- **Consent.** Capture opt-in is personal and uncommitted, and the data stays personal. Team-visible friction is partly a record of a dev's own corrections — readable as performance telemetry. Sharing needs its own consent step, separate from capture.
- **Supply chain.** A CI processor means committing executable workflow config (which `/togi:setup` pointedly refuses to do), parking a long-lived org API key in CI secrets, and pointing an agent that has push/PR rights at injectable input — with no Phase 3 human review, leaving only PR-diff review *after* edits were steered. Same threat shape togi's processing-time guardrail ([§4](#4-privacy--security)) exists to contain. It also shifts billing from each developer's personal account to an org API account.

**If revisited, stage it so every step keeps a human gate:**

1. Event sharing as a **separate opt-in** with a plain "your events become visible to repo readers" disclosure; a push of the friction notes to the shared ref; decliners keep the local-only flow. Consider a pre-push review moment (e.g. push at next session start with a one-line notice) rather than a silent push.
2. **Processing stays interactive**: `update-context-docs` reads the shared ref in addition to the local dir; any opted-in dev processes the team pool with the Phase 2/3 review intact. Captures essentially the full pooling benefit with zero new credentials and nothing executable in git.
3. CI, if any, is **inert**: a scheduled job that counts events on the friction ref and opens an issue at a team threshold ("23 events from 4 devs — run /togi:update-context-docs"). No API key, no agent, no injection surface; replaces the per-dev startup nag with a team-level one.

Full CI processing (agent edits docs unsupervised) stays rejected unless 1–3 prove insufficient — and the injectable-input + credentials − human-gate combination argues against it even then. Default posture if implemented: pooling off for open-source repos with external contributors; reasonable for private team repos.

### Stronger friction-file structure (considered, not decided)

The current friction file is loose positional markdown — type from the `#` heading, body from the first paragraph, an optional `**Misleading doc:**` line, date from the file mtime ([§1](#1-architecture--lifecycle) friction file shape). A proposed upgrade adds minimal YAML frontmatter: `type`, `source` (`model`|`hook`), a real `captured` date (no mtime fragility), optional `area`/`tool`, and an `occurrences` counter the `PermissionDenied` hook bumps on a repeat denial — restoring the recurrence-within-period signal that slug-dedup currently erases. The hook can populate rich frontmatter for free and reliably; the model keeps a minimal subset (`type` + body), with a legacy fallback in `update-context-docs` if frontmatter is missing or malformed. Worth doing; the trade is reintroducing a small inline-syntax burden on the model, kept low by the per-writer split.

### OpenCode (and cross-tool) port (explored, not designed)

The capture *concept* ports; the mechanism is Claude-Code-specific. The retired sweep does **not** port — OpenCode bills Anthropic by API key only (subscription / Agent-SDK-credit billing is prohibited there), so its cost model collapses. Inline capture is the portable shape: the directive text can live in `AGENTS.md` (read by Claude Code via `@import` and by OpenCode natively), and OpenCode's `experimental.chat.system.transform` hook can inject it per request (so no `Stop`-refresh is needed); `session.idle` is the turn-end analog of `Stop`. OpenCode has no auto-memory equivalent. Recorded as a direction, not a commitment.

---

## 10. Verified empirical facts

The load-bearing facts togi's behavior rests on, with how each was established. Re-verify when Claude Code's CLI behavior changes. Some groups below were established for the now-retired end-of-session sweep ([alternative #9](alternatives/09-session-end-resume-sweep.md)) and are preserved here as verified findings in case it is revived.

**Inline capture & hooks (current implementation)**

- Context size is recoverable from the transcript: `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the most recent assistant `usage` block is the input the model saw that turn (live-verified — one session's last turn read ~555K). `Stop` no longer reads this (it switched to a turn counter — [§1](#1-architecture--lifecycle)); the fact is preserved for completeness and in case it is revived.
- The `PermissionDenied` hook writes a denial event with a `denied-<tool>-<cksum>` slug, so an identical repeat denial maps to the same file (dedup). Smoke-tested standalone; the live `PermissionDenied` payload fields (`tool_name`, `tool_input`) are docs-sourced.

**Session & fork behavior (verified; retired sweep — [alternative #9](alternatives/09-session-end-resume-sweep.md))**

- `claude -p --resume <id> --fork-session` carries full session context, returns a new session id, and leaves the original transcript byte-identical. Without `--fork-session`, the resume mutates the user's session (transcript grew 10 → 19 lines and reused the same session id). **Fork is mandatory.**
- `SessionEnd` fires for headless `-p` sessions too (`reason: "other"`) — the sweep child triggers the hook itself, so the recursion guard is load-bearing, not defensive.
- Env vars set on the spawned child (`TOGI_SWEEP=1`) are visible to the child's hooks (verified in both SessionStart and SessionEnd of the child).
- Blocking Stop-hook `reason` text is always user-visible.

**Prompt cache (verified; retired sweep — [alternative #9](alternatives/09-session-end-resume-sweep.md))**

- Cache TTL is 5 minutes from last use, refreshed every turn, and model-scoped (a Haiku read can never use an Opus/Fable cache). This underpinned the retired sweep's warm-cache economics; **one observation under re-verification:** 1-hour-TTL cache writes seen. Detail in [alternative #9](alternatives/09-session-end-resume-sweep.md).

**Detaching the background sweep (retired sweep — [alternative #9](alternatives/09-session-end-resume-sweep.md))**

- `nohup … &` + `disown` is not enough: Claude Code reads hook stdout to EOF before releasing exit, and the backgrounded subshell inherits the hook's pipes. The subshell must redirect its own stdio (`</dev/null >/dev/null 2>&1`) **and** `disown` (Claude Code waitpids children). Regression-tested with a read-to-EOF harness.

**CLI flag hazards (verified)**

- `--allowedTools` / `--disallowedTools` are variadic — they consume the next positional as a tool name, silently swallowing a positional prompt. Deliver the prompt via stdin. (This argv/stdin bug was diagnosed via the `TOGI_DEBUG=1` log — see [§5](#5-activation--opt-in) and Troubleshooting in the README.)
- `--disallowedTools "Bash,…"` (one comma-separated arg) denies even when allow rules match (deny overrides allow), at the permission layer only (cache preserved). `--disallowedTools "*"` is a silent no-op. Pertains to the retired sweep's tool lockdown — see [alternative #9](alternatives/09-session-end-resume-sweep.md).

**Distribution (verified)**

- The installed CLI resolves a pinned `sha` plugin source as documented — a live `/plugin install` and a subsequent pin-bump update both delivered the pinned commit and ran its code. See [§8](#8-supply-chain--releases).

**Docs-sourced, NOT live-verified**

- Hook event payloads and `additionalContext` behavior ([§1](#1-architecture--lifecycle)) — [hooks reference](https://code.claude.com/docs/en/hooks).
- `PostCompact` cannot inject context (no `additionalContext`, no decision control — "shows stderr only") — [hooks reference](https://code.claude.com/docs/en/hooks). `SessionStart` supports `additionalContext` plus a `systemMessage` in the same output ([§1](#1-architecture--lifecycle)) — [hooks reference](https://code.claude.com/docs/en/hooks).
- `SessionStart` with no matcher (or `matcher: "compact"`) fires on `source: "compact"` **before** the first post-compaction model response — no gap turn exists. Live-verified: the hook's stdout appeared as context in the model's first post-compaction response, not the second ([§1](#1-architecture--lifecycle)).
- Settings precedence local > project > user ([§5](#5-activation--opt-in)) — [Claude Code settings](https://code.claude.com/docs/en/settings).
- Protected-paths behavior and that deny rules apply to read-only tools ([§4](#4-privacy--security)) — [permission modes](https://code.claude.com/docs/en/permission-modes#protected-paths), [permissions](https://code.claude.com/docs/en/permissions).
- Skill-from-skill nesting via the `Skill` tool ([§4](#4-privacy--security)) — [skills](https://code.claude.com/docs/en/skills), [tools reference](https://code.claude.com/docs/en/tools-reference).

## Claude Code & API documentation

Every external claim in this document traces to one of these official docs. Grouped by topic:

**Hooks & lifecycle** — [Hooks reference](https://code.claude.com/docs/en/hooks) · [Hooks guide](https://code.claude.com/docs/en/hooks-guide) · [Managing sessions](https://code.claude.com/docs/en/sessions)

**CLI & headless** — [CLI reference](https://code.claude.com/docs/en/cli-reference) · [Run Claude Code programmatically (headless)](https://code.claude.com/docs/en/headless)

**Permissions & settings** — [Configure permissions](https://code.claude.com/docs/en/permissions) · [Permission modes / protected paths](https://code.claude.com/docs/en/permission-modes#protected-paths) · [Claude Code settings](https://code.claude.com/docs/en/settings) · [Tools reference](https://code.claude.com/docs/en/tools-reference)

**Skills** — [Extend Claude with skills](https://code.claude.com/docs/en/skills)

**Plugins & marketplaces** — [Create plugins](https://code.claude.com/docs/en/plugins) · [Plugins reference](https://code.claude.com/docs/en/plugins-reference) · [Create & distribute a marketplace](https://code.claude.com/docs/en/plugin-marketplaces) · [Discover & install plugins](https://code.claude.com/docs/en/discover-plugins)

**Cost & models** — [Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) · [Pricing](https://platform.claude.com/docs/en/about-claude/pricing) · [Models overview](https://platform.claude.com/docs/en/about-claude/models/overview)
</content>
</invoke>
