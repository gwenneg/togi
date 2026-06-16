# Togi internals & deep reference

This document is the deep-dive companion to the [README](../README.md). The README is the high-altitude on-ramp; everything here is for someone who wants the *why* behind a specific topic — the cost model, the security posture, the release process, the rejected alternatives.

## Contents

1. [Architecture & lifecycle](#1-architecture--lifecycle)
2. [Why a session-end sweep](#2-why-a-session-end-sweep-alternatives-considered)
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

Togi has three moving parts — two session-lifecycle hooks and one skill (see the [hooks reference](https://code.claude.com/docs/en/hooks) and [hooks guide](https://code.claude.com/docs/en/hooks-guide) for the hook mechanism):

- **`SessionEnd` hook** (`scripts/session-end.sh`) — when an enabled session ends, it forks a detached headless `claude -p --resume --fork-session` process ([headless mode](https://code.claude.com/docs/en/headless)) that sweeps the just-ended session for friction events and writes them as a JSON file under `.togi/friction/pending/`.
- **`SessionStart` hook** (`scripts/session-start.sh`) — counts pending friction events; once the count reaches `TOGI_EVENT_THRESHOLD`, it injects a reminder to process them (`SessionStart` stdout is added to context per the [hooks reference](https://code.claude.com/docs/en/hooks)). In repos that adopted togi but where the developer hasn't opted in, it shows a single opt-in notice instead.
- **`/togi:update-context-docs` [skill](https://code.claude.com/docs/en/skills)** — groups accumulated events by root cause, decides which docs to fix, edits them, opens a PR, and archives the processed events.

The full loop:

```
session ends → session-end.sh → forked headless sweep → friction files written to .togi/friction/pending/
                                                                    ↓
                               next session start → session-start.sh → "12 friction events. Update the docs."
                                                                    ↓
                               developer runs /togi:update-context-docs → docs edited → PR opened
                                                                    ↓
                               PR merged → agent reads better docs → fewer stumbles next session
```

### Which session ends are swept

The sweep runs only on *true* session ends. The `SessionEnd` payload's `reason` field (docs-sourced from the [hooks reference](https://code.claude.com/docs/en/hooks) — only `other` live-verified) takes one of: `clear` (after `/clear`), `resume` (before re-opening with `--resume`/`--continue`), `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other`. Headless `-p` ends report `other` (live-verified).

The sweep skips two as non-final ends:

- `resume` — the session is not over; its real exit fires `SessionEnd` again. Sweeping on resume would bill twice and capture duplicate events for the same session.
- `bypass_permissions_disabled` — a mid-session mode change, not a termination.

Log live `reason` values (`TOGI_DEBUG=1`) before relying on any finer distinctions, and re-verify this table when CLI behavior changes.

### The recursion guard

`SessionEnd` fires for headless `-p` sessions too — the sweep child triggers the hook itself. The child is launched with `TOGI_HEADLESS=1`, and both hooks exit immediately when they see it. Without this guard the sweep would chain infinitely. The guard is load-bearing, not defensive.

### Detaching the sweep

Detaching the sweep takes more than `nohup … &` + `disown` (which alone left session exit blocking for the sweep's full duration): Claude Code reads hook stdout until EOF before releasing exit, and the backgrounded subshell inherits the hook's pipes — `nohup` redirects only claude's own fds. So both halves of the detach are load-bearing: the subshell must redirect its own stdio (`</dev/null >/dev/null 2>&1`), **and** `disown` removes the job from the table (Claude Code waitpids its children). Regression-tested with a read-to-EOF harness emulating Claude Code (`tests/session-end-argv.sh`).

### Friction file shape

A friction file is one session's sweep: an optional per-sweep `sweep_cost_usd` header and an `events` array. Each field lives where its consumer reads it — the cost aggregate in the header (summed across files for the PR), and everything consumed *per event* on the event:

- `date` — the recurrence comparison, display, and PR line all operate per event, and events regroup across sweeps, so the date travels with each event
- `body` — drives grouping, placement, the recurrence match, and the edit
- `type` — one of `correction`, `clarification`, `mistake`, `denial`; PR metrics + display label
- `captured_by` — the confidence signal: an event captured by the Haiku fallback is lower-confidence (the *model*, not the cache state, sets capture quality)
- `misleading_doc` (optional) — a high-confidence placement hint (see [§7](#7-processing-friction-into-docs))

The session-start counter reads `.events | length` (0 for null/missing, so a malformed file counts as nothing, not an error).

---

## 2. Why a session-end sweep (alternatives considered)

The core problem: detect friction events (corrections, clarifications, mistakes, tool denials) reliably, without taxing the session, at acceptable cost, with an honest privacy story. Each approach trades these off differently.

| # | Approach | Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|---|---|
| 1 | CLAUDE.md import, per-message instructions | Low, unmeasurable | Invisible, but per-message attention tax | ~free | No | Minimal |
| 2 | Unconditional blocking Stop hook | Medium | **Prompt wall every turn** | ~$1+ (extra inference/turn) | No | Low |
| 3 | Conditional Stop hook (keyword grep on transcript) | Medium, keyword-blind | Occasional visible block | Low | No | Medium |
| 4 | `UserPromptSubmit` silent `additionalContext` | Low (advisory only) | Invisible | ~free | No | Low |
| 5 | Layered: hook-parsed denials + keyword fast path + once-per-session sweep | High | One visible block/session | Low | No | High |
| 6 | Per-turn Haiku classifier in Stop hook | High | Invisible, +latency every turn end | Medium | Yes, per turn | Medium |
| 7 | SessionEnd → headless `claude -p` over transcript (fresh context) | High | Invisible | Medium (full re-read, no cache) | Yes, per session | Medium |
| 8 | SessionEnd digest → sweep at next SessionStart | Medium-high | Work at top of next session | Low | No | Medium |
| 9 | **SessionEnd → `claude -p --resume --fork-session` sweep** *(chosen)* | **High** | **Invisible** | **~$0.05–0.20 (warm cache)** | Yes, per session | Medium |

### Why each was rejected

**1. CLAUDE.md import** — detection rests on the model voluntarily interrupting its own task per message; standing instructions habituate, recall is unknown and unmeasurable, and capture interrupts the response to the very correction that triggered it. Its virtues (zero cost, zero API calls, dead simple) are why it shipped first.

**2. Unconditional Stop hook** — fixed the attention problem (just-in-time enforcement) but a blocking Stop hook's `reason` is user-visible by design: a 22-line prompt rendered every turn. Also the most expensive option — one extra inference per turn plus the reason accumulating in context.

**3. Conditional Stop hook** — keyword filters have a systematic blind spot: corrections that don't use correction words. Bounded misses, but a whole phrasing style stays invisible forever.

**4. UserPromptSubmit injection** — silent, but advisory-only at the moment of least hindsight; effectively approach 1 with better recency.

**5. Layered design** — best recall without API calls, but three mechanisms to maintain, and still one visible block per session. The complexity wasn't buying enough over 9.

**6. Per-turn Haiku classifier** — semantic recall with no UI noise, but adds latency to every turn end and N API calls per session; breaks the privacy claim N times instead of once.

**7. Fresh-context transcript analysis** — works, but pays full input price (no cache reuse) and reads a serialized transcript instead of inhabiting the conversation; strictly dominated by 9 once `--fork-session` was verified.

**8. Deferred sweep at next SessionStart** — the only high-recall option preserving "no out-of-session API calls"; kept as the documented fallback if the consent change proves unpopular. Costs: latency at the top of the next session, sweeps a digest rather than the live context, never runs if no next session.

**9. Resume sweep (chosen)** — full-session hindsight from the model that lived the session (verified: fork carries complete context, original transcript untouched), zero session noise, and the cheapest of the high-recall options because the warm prompt cache replays the session at ~0.1× input price. Trades away: one API call per session (consent + cost disclosure required), no sweep on crashed sessions, detached-process fragility.

---

## 3. Cost model

**Typical cost: $0.05–$0.20 per session**, billed at standard API rates. The sweep is a headless `claude -p` run, so it draws from Anthropic's separate monthly [Agent SDK credit](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) — for subscription users a per-plan dollar credit (≈$20 Pro / $100 Max 5x / $200 Max 20x, no rollover), not your general plan usage limits. Once that credit is exhausted, sweeps pause until it resets unless you have enabled overflow ("usage credits") billing. The sweep runs **only for opted-in developers** — an installed-but-unenabled plugin makes no API calls at all.

### Which account gets billed (ambient `ANTHROPIC_API_KEY`)

The "draws from the Agent SDK credit" line above holds **only when no higher-precedence credential is present in the sweep's environment**. The `SessionEnd` hook is a child of your Claude Code session, so the sweep inherits that session's environment — and `session-end.sh` sets no credential of its own (no `--bare`, no `unset`), so Claude Code's normal [authentication precedence](https://code.claude.com/docs/en/authentication.md#authentication-precedence) applies: cloud-provider creds → `ANTHROPIC_AUTH_TOKEN` → **`ANTHROPIC_API_KEY`** → `apiKeyHelper` → `CLAUDE_CODE_OAUTH_TOKEN` → subscription OAuth. The API key ranks **above** the subscription login.

Consequence: a developer with `ANTHROPIC_API_KEY` exported (common in dev shells, CI, and org setups) has every sweep **billed to that key at standard API rates** — not the Agent SDK credit, and not their subscription. And because the approval prompt that gates a custom key in interactive mode is skipped in headless mode — per the [auth docs](https://code.claude.com/docs/en/authentication.md#authentication-precedence), "In non-interactive mode (`-p`), the key is always used when present" — this redirect happens **silently**, with no consent step at sweep time. This is the supported way to run togi on an API-key account rather than a subscription; it is also a billing surprise if the key is ambient and unintended. To force subscription billing regardless of environment, `unset ANTHROPIC_API_KEY` in the shell that launches Claude Code.

### Derivation (pricing arithmetic, not measured invoices)

- A sweep replays the **entire session context as input** via `--resume --fork-session`; the capture prompt (~200 tokens) and the JSON output (hundreds of tokens) are negligible next to it.
- Warm prompt-cache reads bill at **~0.1× base input price** (cache reads are 0.1× base input, 5-minute cache writes 1.25× — see [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)).
- Reference case: a **150K-token session at Opus-class pricing** ($5/MTok input → ~$0.50/MTok cache-read) ≈ **$0.08 per sweep**. The $0.05–$0.20 range stretches that across ~50K–300K-token sessions.
- Cold sweep = full input price = ~10× warm (~$0.75 at 150K on Opus). The Haiku fallback caps the cold case at cold-Haiku pricing ($1/MTok → ~$0.15 at 150K) — roughly cold-Opus ÷ 5, which is why `session-end.sh` falls back to Haiku rather than sweeping cold on the session's model.

Prices used (per MTok, input / ~cache-read; current rates on the [pricing page](https://platform.claude.com/docs/en/about-claude/pricing) and [models overview](https://platform.claude.com/docs/en/about-claude/models/overview)): Opus 4.8 $5.00 / ~$0.50 · Sonnet 4.6 $3.00 / ~$0.30 · Haiku 4.5 $1.00 / ~$0.10 · Fable 5 $10.00 / ~$1.00.

Caveats: the range is **Opus-referenced** — sessions on cheaper models sweep cheaper, and a long **Fable 5** session can exceed it (~$1/MTok cache-read → ~$0.25 at 250K tokens). When prices change, re-derive as `session tokens × cache-read price` and update the figure everywhere it appears (README Cost, setup Phase 1, `.togi/togi.md` template, plugin descriptions, the opt-in notice in `session-start.sh`).

### The cache rule

The prompt cache has a **5-minute TTL** from the last exchange, refreshed on every turn (verified; the default ephemeral cache lifetime is 5 minutes per the [prompt-caching docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)). Because togi launches the sweep immediately at session end, an active hour-long session sweeps warm, replaying its tokens at ~0.1× input price. Only a session whose last exchange is **more than 290 seconds old** at session end (just under the 5-minute TTL) is treated as cold.

The cache is **model-scoped**: a Haiku sweep can never read an Opus or Fable cache. So a cold sweep can't downgrade to Haiku and reuse the warm cache — there is no warm cache for it to read. Cold means full input price on *some* model; the fallback is Haiku because cold Haiku (~$0.15 at 150K) costs roughly one-fifth of cold Opus.

### Telemetry: `--output-format json` (verified)

The sweep runs with `--output-format json` ([CLI reference](https://code.claude.com/docs/en/cli-reference), [headless mode](https://code.claude.com/docs/en/headless)), which wraps the model's text in a result envelope carrying measured telemetry. This turns the cost estimate above into measured invoices: each sweep records its actual cost (`sweep_cost_usd`) in the friction file header, and `/togi:update-context-docs` reports the summed sweep cost in its PR metrics.

Live-verified on this account (haiku, fresh `-p` plus a `--resume --fork-session` of it):

- **`total_cost_usd` covers exactly this run, not the resumed session's prior spend.** Reconciled to floating-point identity: the fork-resume's reported cost ($0.0031054) equals its own `usage` block priced at list (input ×$1 + cache-read ×$0.10 + 1h-cache-write ×$2 + output ×$5 per MTok for Haiku). The resumed session's prior turns appear only as the input replay — the fork's `cache_read_input_tokens` (23,734) matched the base session's prefix (17,704 read + 6,030 created) — precisely the incremental cost togi's model describes.
- **Client-side only.** The flag changes output formatting, not the API request — prompt and tool definitions are untouched, so the warm-cache property is preserved.
- Envelope fields used: `.result` (the events array, a JSON-encoded string — extracted with `fromjson`, every failure degrading to zero events), and `total_cost_usd` → stamped into the friction file header as `sweep_cost_usd`. Everything else goes to the debug log only, because the skill never reads it: `usage.cache_read_input_tokens` / `cache_creation_input_tokens` (the prediction-vs-measured cache line — the cache-TTL instrument; cache writes are a suspected cost driver, since 1h-TTL writes bill at 2× base input and a prefix mismatch re-writes the whole session at that premium), `is_error`, `duration_ms`, fork `session_id`. Ignored entirely: `modelUsage`, `num_turns`, `iterations`. `total_cost_usd` is optional — the friction write must never fail for lack of it.

**Open question (observed, not concluded):** both fresh `-p` runs wrote `cache_creation.ephemeral_1h_input_tokens` > 0 and zero 5-minute-TTL tokens — i.e. current Claude Code requests **1-hour-TTL** cache writes, at least for headless runs. The cost model, the 290 s cold threshold, and the Haiku fallback all rest on the verified 5-minute TTL. If interactive sessions also cache at 1 h, the cold threshold is wildly conservative and the Haiku fallback fires needlessly — sessions idle under an hour would still sweep warm on their own model. The `sweep telemetry:` debug log line (predicted warm/cold vs measured cache reads) is the instrument: sweeps predicted cold that show large `cache_read_input_tokens` settle it. Revisit the threshold once real data accumulates; do not change it on one observation.

---

## 4. Privacy & security

### Privacy posture

The sweep resumes your session via `claude -p --resume --fork-session` on your own account ([CLI reference](https://code.claude.com/docs/en/cli-reference), [managing sessions](https://code.claude.com/docs/en/sessions)). Your session transcript is not sent to any third party — the sweep runs as a headless Claude Code process under your own credentials, exactly as if you had resumed the session yourself. `--fork-session` is mandatory: per the [sessions docs](https://code.claude.com/docs/en/sessions) forking "copies the history into a new session ID, leaving the original unchanged" (verified — see [§10](#10-verified-empirical-facts)).

Friction files are written locally under `.togi/friction/` (`pending/`, then `archive/` once processed — both git-ignored). Any developer can opt out with `/togi:disable`.

**Known limitation:** sessions ended by crash or SIGKILL are not swept. Recurring doc gaps in those sessions will be caught on later sessions.

### Sweep tool lockdown (verified)

The sweep needs zero tools, so **every tool is denied** (`--disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Read,Glob,Grep"` — see [configure permissions](https://code.claude.com/docs/en/permissions), [tools reference](https://code.claude.com/docs/en/tools-reference)). This is the core injection defense — swept session content is untrusted input.

- Headless `claude -p` **inherits permission allow rules** from user/project/local settings ([permissions](https://code.claude.com/docs/en/permissions)): in a project whose settings allow `Bash(echo *)`, a plain `-p` session executed Bash without prompting. A prompt injection in swept session content could therefore run any pre-allowed command, unsupervised.
- `--disallowedTools "Bash,Edit,…"` (comma-separated, single arg) denies the listed tools even when allow rules match — **deny overrides allow** ([permissions](https://code.claude.com/docs/en/permissions): a denied tool cannot be re-allowed at any level, and when both lists name a tool, `disallowedTools` wins). It acts at the permission layer only, so the tool definitions in the API request are unchanged and the warm prompt cache is preserved.
- `--disallowedTools "*"` is a silent no-op: bare `*` matches no tool name (Bash still executed). Never use it.
- `--disallowedTools` is **variadic** — it consumes the next positional as a second tool name. So the prompt must go via **stdin** (`printf '%s' "$PROMPT" | claude …`); a positional prompt after `--disallowedTools` is silently swallowed, leaving a promptless `--resume` that falls into the "continue a deferred tool" path and fails with "No deferred tool marker found". (Same hazard on `--allowedTools`.)
- `--bare` is unsuitable: per CLI help it restricts auth to `ANTHROPIC_API_KEY`/`apiKeyHelper` (OAuth and keychain never read), which breaks subscription users; and settings files are not in its documented skip list, so it is not shown to bypass inherited allow rules anyway.
- `--tools ""` would remove tool definitions from the request — tool definitions are part of the cached prefix, so every sweep would run cold, breaking the cost model.
- **Read/Glob/Grep are denied too:** injected session content could otherwise direct the sweep to read local secrets (`.env`, credentials) into an event `body` — which `update-context-docs` later pushes into a pull request, completing a slow exfiltration channel. WebFetch/WebSearch (the fast channels) were already denied. Docs-sourced, NOT live-verified: the permissions docs state deny rules apply to read-only tools even though those tools normally require no permission prompt.
- **Known gap:** the deny list covers built-in tools only. MCP tools auto-allowed by project settings (e.g. `enableAllProjectMcpServers`) are not covered — a bare `mcp__*` deny pattern is unverified, and `--strict-mcp-config` would drop MCP tool definitions from the request (cold cache for MCP-using sessions). Revisit if a verified blanket deny becomes available.

Re-verify these when CLI behavior changes.

### Injection guardrail at processing time

Event content derives from session transcripts and is injectable, so it is not trusted input for anything beyond doc prose. `update-context-docs` targets must be **in-repo documentation files** — never settings, code, CI, or hook files — regardless of what an event's `body` or `misleading_doc` names. The PR-as-exfiltration channel is the same reason the sweep denies Read.

### Protected paths vs. skill permissions (docs-sourced, NOT live-verified)

`.claude` is on Claude Code's fixed [protected-directories list](https://code.claude.com/docs/en/permission-modes#protected-paths). Writes to protected paths are **never auto-approved** in any mode except `bypassPermissions`, and the check runs **before** allow rules are evaluated — so neither `permissions.allow` in settings nor a skill's `allowed-tools` can pre-approve a write to `.claude/settings.json` or `.claude/settings.local.json` (the two are treated identically). Rationale: settings define permissions, so nothing running under the permission system may rewrite them silently.

Consequences for togi:

- The settings writes in `/togi:enable`, `/togi:disable`, and `/togi:setup` **always prompt**. Acceptable — the write toggles a consent flag, and the prompt puts that approval in front of exactly the right person at the right moment.
- `enable` and `disable` carry **no `allowed-tools`**: an allowlist cannot deliver promptless operation for skills whose whole job is a protected write, so it buys nothing.
- `setup` keeps `allowed-tools` only for steps pre-approval can actually serve: `Write`/`Read`/`Edit` for the files it commits (`.gitignore`, the CONTRIBUTING/README pointer, and the adoption note `.togi/togi.md` — all outside Claude Code's protected `.claude/`, so the grant actually pre-approves them), and the git/gh flow. (Moving the adoption note to `.togi/` is what made it pre-approvable; under `.claude/` it was protected and prompted regardless.) Everything else was removed: `Bash(mkdir*)`, `Bash(touch .claude/*)`, `Bash(mv .claude/*)`, later `Bash(jq*)` and `Bash(grep*)`. A dead grant is worse than a prompt.
- Whether the check inspects Bash redirect targets (`> .claude/foo.tmp`) or `mv` side effects is undocumented. Togi deliberately does **not** rely on that either way — routing writes through a vehicle the checker might miss would be evading a safety feature via an undocumented gap.
- `setup` Phase 3 delegates the opt-in to the `enable` skill via the `Skill` tool (`Skill(togi:enable)` in allowed-tools; `enable` accepts `repo`/`all` to skip its scope question), so the opt-in commands live in exactly one file. Docs-sourced ([skills](https://code.claude.com/docs/en/skills), [tools reference](https://code.claude.com/docs/en/tools-reference)): the Skill tool "executes a skill within the main conversation" and `Skill(name)` is the documented permission syntax — but skill-from-skill nesting is NOT explicitly documented. Verify on the first live setup run.

---

## 5. Activation & opt-in

`TOGI_ENABLED` defaults to **`0`** (opt-in per developer): an installed plugin is dormant — hooks exit immediately, no sweep, no files, no cost. It is read from the settings `env` block ([Claude Code settings](https://code.claude.com/docs/en/settings)). Each developer opts in personally via `/togi:setup` (offered at the end) or `/togi:enable`, at one of two scopes, both uncommitted:

- **repo**: `env.TOGI_ENABLED = "1"` in `.claude/settings.local.json` — this repo only
- **global**: same key in `~/.claude/settings.json` — every repo for this user

**Why opt-in.** `/plugin marketplace add` registers user-globally (`~/.claude/plugins/known_marketplaces.json` — there is no project-scoped form), and `/plugin install` defaults to **user scope** ([discover & install plugins](https://code.claude.com/docs/en/discover-plugins)), so the hooks fire in every repo on the machine. Enabling by default would therefore have meant billing sweeps in unrelated repos and writing `.togi/friction/` files into repos whose `.gitignore` was never configured — an accidental-commit/leak hazard. Opt-in also makes install scope irrelevant: a user-scope install is safe because it is dormant everywhere the developer hasn't enabled it.

### Precedence

A repo-local `TOGI_ENABLED=0` overrides a global `1` — settings precedence is local > project > user, below command-line args and managed settings ([settings precedence](https://code.claude.com/docs/en/settings), docs-sourced, NOT live-verified) — which is what keeps `/togi:disable` meaningful for global opt-ins. The same precedence cuts the other way: a global `0` does **not** override repo-local `1`s, so repos opted in individually must be disabled individually. The disable skill's global output states this exception instead of over-promising.

### One-time opt-in notice

In repos carrying the committed adoption note `.togi/togi.md` (see [§6](#6-team-adoption--distribution)), `SessionStart` shows not-yet-opted-in developers a single notice (cost + `/togi:enable`) and drops a marker at `.togi/togi-notice-shown` (git-ignored by setup) so it never repeats. Repos without the adoption note stay completely silent — that is the guard against user-scope installs nagging in unrelated projects.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `0` | The only switch, **off by default**. `1` activates friction capture — including the end-of-session sweep (one API call). A repo-local `0` overrides a global `1`. |
| `TOGI_EVENT_THRESHOLD` | `10` | Friction events accumulated before the startup reminder appears. See the cap/threshold decoupling in [§7](#7-processing-friction-into-docs). |
| `TOGI_DEBUG` | `0` | `1` writes structured hook logs to `.togi/togi.log` in the project directory. |

`TOGI_HEADLESS` and `TOGI_SWEEP` are internal — set on the spawned sweep child, not user-facing.

### Rejected, do not reintroduce

- `TOGI_SWEEP_ENABLED` as a *committed project-level* consent flag — consent stays personal and uncommitted.
- `TOGI_MIN_TURNS` (skip sweeps for sessions below a turn threshold) — tried and removed; stays out.

---

## 6. Team adoption & distribution

`/togi:setup` commits **nothing executable**: no `extraKnownMarketplaces`, no `enabledPlugins`, no marketplace registration, no plugin enablement.

Committed marketplace/plugin entries are the platform's documented team pattern ("Require marketplaces for your team" — see [plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces) and [Claude Code settings](https://code.claude.com/docs/en/settings)), and teammates do get a prompt at folder-trust — but the prompt's decline behavior is undocumented, hooks get no separate trust step, and even "dormant" hooks execute at every session boundary. Committing enablement would grant togi's author code execution on every teammate's machine *on their behalf*, which contradicts togi's own supply-chain posture: code lands on a machine only when its owner installed it.

Instead the repo carries an **adoption note**: `.togi/togi.md` (install commands + cost model; inert) plus a pointer section in `CONTRIBUTING.md`/`README.md`, with the setup PR as the team's review artifact. The adoption note doubles as the signal for the one-time opt-in notice ([§5](#5-activation--opt-in)).

`/togi:setup` commits three inert files:

1. `.togi/togi.md` — the adoption note (install commands, cost model)
2. a pointer section in `CONTRIBUTING.md` (or `README.md`)
3. `.gitignore` entries — `/.togi/friction/`, `/.claude/settings.local.json`, `/.togi/togi.log`, `/.togi/togi-notice-shown` (never `.togi/` wholesale — it holds the committed adoption note — nor `.claude/` wholesale, which would hide files teams commit deliberately)

Each developer then installs togi deliberately (the two `/plugin` commands, then `/togi:enable`). Developers who already have the plugin get a one-time notice in adopted repos pointing them to `/togi:enable`; beyond that, nothing runs on their account without their say-so.

**Trade-off accepted:** adoption is three manual commands per developer instead of zero, and developers who never install the plugin see no in-product discovery at all — the pointer section carries that load.

---

## 7. Processing friction into docs

`/togi:update-context-docs` is the interactive stage that turns accumulated events into a doc PR. The skill file (`skills/update-context-docs/SKILL.md`) is the procedure; this section is the rationale behind its design choices.

### Doc targeting happens here, not at sweep time

The sweep does not name the doc to fix; `update-context-docs` decides placement. The sweep is structurally unable to: it runs with every tool denied ([§4](#4-privacy--security)), so it cannot see the repo's doc tree — the only docs it knows are those that happened to be in the session's context, and friction events exist precisely because the relevant knowledge was *not* in context. Any doc it named would usually be a guess (`CLAUDE.md` by default, or an invented path), and a guessed path that doesn't exist is an event silently dropped at edit time then erased at cleanup — a recall hole at the last mile. Sweep-time targeting also fragments aggregation: two sessions naming different docs for one root cause look unrelated.

The split follows what each stage can actually know:

- **The sweep captures only what it alone knows.** `misleading_doc` (optional) names a doc only when that doc was in the session's context *and* contained wrong or outdated guidance — the one case where sweep-time identification is reliable (the sweep watched the doc mislead) and hard to reconstruct later from a one-paragraph `body`. Missing-knowledge events carry no doc field; the `body` is required to name the topic precisely instead.
- **`update-context-docs` decides placement.** It has everything the sweep lacks: repo visibility (the actual doc tree, current rather than capture-time — paths go stale), all events across sessions (root-cause grouping: one fix may serve many events, one event may need several docs, a new doc may be warranted), and the user in the loop reviewing proposed targets before any edit. It costs nothing extra — the skill already read every target file before editing.
- **Injection guardrail:** targets must be in-repo documentation files — never settings, code, CI, or hook files ([§4](#4-privacy--security)).

Trade-off accepted: placement judgment concentrates in one interactive run rather than being spread across sweeps. That run is exactly where the user already reviews events (and the PR is reviewed again by the team) — a better seat for that judgment than an unsupervised, tool-denied headless sweep.

### Sweep output hardening: schema gate + significance cap

Two small guards on what a sweep can inject into the pipeline, shipped together:

**Schema gate (`session-end.sh`).** A malformed event from the sweep — missing field, wrong type value, a bare string in the array — would otherwise flow into the friction file and surface as confusion at processing time, possibly weeks later and far from its cause. A jq filter keeps only objects carrying `type`/`captured_by`/`body` as non-empty strings with `type` one of the four known values, and the drop count is logged (`TOGI_DEBUG=1`). `misleading_doc` is deliberately not checked — it is optional by design, so absence is legitimate. The same filter is reused for both the count and the file write, so the two cannot disagree. The optional-field schema made this *more* necessary, not less: once "field missing" is sometimes valid, only an explicit gate can tell valid-sparse from malformed. Covered by the regression test.

**Significance cap (capture prompt).** One overzealous sweep could emit a dozen marginal events and instantly trip the startup reminder — and the reminder's credibility is a UX asset: it only works if it is rare and deserved. The prompt allows at most the five most significant events, ordered most significant first. The cap bounds per-session noise; the ordering means a truncated review still sees the strongest events first.

The cap (5) and the reminder threshold (default `TOGI_EVENT_THRESHOLD` = 10) are deliberately **decoupled** — they answer different questions. The cap is a *per-session* noise bound. The threshold is a *batch size*: how many accumulated events warrant asking the developer to process them. Setting it as low as the cap would let one productive session trip the reminder, producing a thin PR that gives the root-cause grouping nothing to work with and spends the reminder's credibility on a low-signal batch. Threshold 10 spans a few sessions so grouping has material, while staying low enough that friction does not rot (a stale gap keeps the agent stumbling). A single high-friction session loses nothing: its events persist and trip the reminder one session later. Going much above ~15 would make the feedback loop sluggish.

### Feedback loop: processed-event archive + recurrence detection

Togi's promise is "PR merged → agent reads better docs → fewer stumbles", but nothing ever verified the last arrow — and the cleanup phase actively destroyed the data needed to check, `rm`-ing friction files after processing. A gap recurring *after* its fix landed is the most valuable signal in the system (the rule is too weak, lives in a doc agents don't read, or the PR never merged) and was indistinguishable from a brand-new event.

Now `update-context-docs` **archives instead of deletes**: one file per run under `.togi/friction/archive/`, every event (excluded ones included) annotated with `processed_date`, `outcome` (`doc_updated`/`excluded`), and `target_docs`. Before editing, the skill compares incoming event groups against the archive — semantically, by `body` text (free-form prose, so compare meaning, not strings) — and flags:

- **Recurrence after fix** (`doc_updated`, event `date` > `processed_date`): the fix didn't take. Severity floor: medium; strengthen or relocate the previous rule instead of appending a near-duplicate. Caveat the skill is told about: a recurrence may just mean the fix PR hasn't merged yet.
- **Recurrence after exclusion**: previously dismissed as noise and came back — surfaced to the user as "probably real after all".

Design constraints honored:

- Pending and archived events live in sibling directories — `.togi/friction/pending/` (written by the sweep, counted by the session-start reminder) and `.togi/friction/archive/` (written at processing, read only by the recurrence check) — so every consumer reads exactly the directory it means; no depth-limiting convention for a scan to forget.
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
   "source": { "source": "github", "repo": "gwenneg/togi", "sha": "<40-char commit>" }
   ```
   Installing or updating togi fetches the plugin from that exact commit, not from `main`. Each release commit also carries a human-readable tag (e.g. `vX.Y.Z`) for reference, but the pin resolves the SHA, not the tag. A relative `"./."` source would instead track whatever ref the catalog was fetched at (effectively `main`) — the explicit `github` + `sha` source is what decouples the code users run from `main`.

The consequence: **work-in-progress on `main` never reaches users.** A new version reaches them only when (a) the SHA pin is deliberately bumped *and* (b) they choose to refresh the catalog and update the plugin.

### Why this design (and why it's the strongest posture available)

The goal is three properties, in priority order:

- **No silent execution.** Auto-update would push whatever is on `main` to every user automatically — an un-recallable channel where a single bad commit (or a compromised account) becomes instant, unsupervised code execution everywhere. Turning auto-update off removes that channel: updates require a human decision on the user's side.
- **Tamper-evidence / verifiability.** Pinning to a commit `sha` rather than a branch or a tag means git's content-addressing fixes the exact bytes users run. A branch (`"./."`, the default) ships every commit; a tag (`ref`) can be force-moved; a **SHA cannot be moved or re-pointed**. Anyone can verify what they run by comparing the pinned SHA in `marketplace.json` against the repository history and inspecting the tree at that commit. This is the strongest integrity guarantee obtainable in a model where the consumer git-fetches source and the platform offers no signing.
- **Deliberate, reviewable releases.** Because the SHA bump is an explicit commit to `main`, every release is a single, auditable change rather than an implicit side effect of pushing code.

Given the platform's constraints (no plugin signing, hooks trusted implicitly, source fetched directly from git), **SHA-pin + auto-update-off is the most secure configuration available**: it strictly dominates the alternatives — a relative `"./."` source (tracks `main`, ships everything), a `ref`/tag pin (mutable), or auto-update on (silent) — on every one of the three properties above.

### `version` is omitted on purpose

`version` is Claude Code's **update cache key** (resolution order: `plugin.json` `version` → marketplace entry `version` → source commit SHA — see the [plugins reference](https://code.claude.com/docs/en/plugins-reference)). **`version` is deliberately omitted from `plugin.json`** so the identity falls back to the pinned source SHA — making the SHA both the integrity pin and the cache key. A release is then a **single** `sha` bump: it changes the identity (triggers the update) and fixes the code (integrity) at once, with no second knob to keep in sync. The alternative — keeping an explicit `version` — would force bumping both `version` and `sha` in lockstep every release, a drift footgun where SHA-only ships nothing and version-only ships stale code. Trade-off accepted: the in-tool plugin version is now a commit SHA rather than a friendly string (human-readable naming lives in git tags + GitHub Releases).

### Honest residual risks

This posture is not a complete defense, and the gaps point to complementary controls:

- **The pin lives on `main`.** Anyone who can write to `main` — via a compromised account or a merged malicious PR — can rewrite the SHA. Pinning gives deliberate releases and verifiability, **not** protection of `main` itself. That requires account hardening (hardware 2FA, no long-lived tokens), branch protection with required reviews and status checks, and signed commits/tags.
- **The catalog is an unpinned branch fetch.** When a user refreshes the catalog they pull `main`'s *current* `marketplace.json`, so a rewritten SHA is picked up on their next refresh. This is inherent to the catalog being the update channel; signed + protected `v*` tags and the SHA pin reduce, but do not eliminate, the exposure.
- **No update notifications.** Claude Code does not tell users when a new version exists.

### Cutting a release

Releases are deliberate — pushing to `main` does **not** ship code to users.

1. Land all changes on `main`. The final commit is the release commit. If the plugin `description` changed, keep `plugin.json` and the `marketplace.json` plugin entry identical — nothing enforces it, and they drift otherwise.
2. Tag the release commit and push the tag (human-readable naming only — the pin resolves the SHA, not the tag):
   ```bash
   git tag -s vX.Y.Z -m "togi vX.Y.Z" && git push origin vX.Y.Z
   ```
   Prefer a **signed** tag (`-s`) and protect `v*` tags with a ruleset as hygiene.
3. Set `sha` in `.claude-plugin/marketplace.json` to the full 40-char SHA of the release commit, and commit it to `main`. **This single bump is the release**: changing the pinned SHA changes the plugin's identity (so Claude Code detects an update) *and* fixes the exact, immutable code users run (tamper-evidence).
4. Publish a [GitHub Release](https://github.com/gwenneg/togi/releases) with notes (`gh release create vX.Y.Z --generate-notes`) so users have a discovery signal and a changelog to evaluate the update against.

> **Verified:** a pinned-SHA bump delivers updates. With `version` omitted, the plugin identity falls back to the source commit SHA; bumping the pin (`241c78b` → `41e0a31`) then running `/plugin marketplace update` + `/plugin update togi@togi` moved an installed client to the new commit and ran the new hook code (the new telemetry stamps appeared in its output). A live `/plugin install` of a pinned `sha` source also resolved as documented. Re-verify if a Claude Code update changes plugin resolution.

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
- **Supply chain.** A CI processor means committing executable workflow config (which `/togi:setup` pointedly refuses to do), parking a long-lived org API key in CI secrets, and pointing an agent that has push/PR rights at injectable input — with no Phase 3 human review, leaving only PR-diff review *after* edits were steered. Same threat shape the sweep lockdown exists to prevent. It also shifts billing from each developer's personal account to an org API account.

**If revisited, stage it so every step keeps a human gate:**

1. Event sharing as a **separate opt-in** with a plain "your events become visible to repo readers" disclosure; session-end pushes the friction file to the shared ref; decliners keep the local-only flow. Consider a pre-push review moment (e.g. push at next session start with a one-line notice) rather than a silent push at session end.
2. **Processing stays interactive**: `update-context-docs` reads the shared ref in addition to the local dir; any opted-in dev processes the team pool with the Phase 2/3 review intact. Captures essentially the full pooling benefit with zero new credentials and nothing executable in git.
3. CI, if any, is **inert**: a scheduled job that counts events on the friction ref and opens an issue at a team threshold ("23 events from 4 devs — run /togi:update-context-docs"). No API key, no agent, no injection surface; replaces the per-dev startup nag with a team-level one.

Full CI processing (agent edits docs unsupervised) stays rejected unless 1–3 prove insufficient — and the injectable-input + credentials − human-gate combination argues against it even then. Default posture if implemented: pooling off for open-source repos with external contributors; reasonable for private team repos.

---

## 10. Verified empirical facts

The load-bearing facts togi's behavior rests on, with how each was established. Re-verify when Claude Code's CLI behavior changes.

**Session & fork behavior (verified)**

- `claude -p --resume <id> --fork-session` carries full session context, returns a new session id, and leaves the original transcript byte-identical. Without `--fork-session`, the resume mutates the user's session (transcript grew 10 → 19 lines and reused the same session id). **Fork is mandatory.**
- `SessionEnd` fires for headless `-p` sessions too (`reason: "other"`) — the sweep child triggers the hook itself, so the recursion guard is load-bearing, not defensive.
- Env vars set on the spawned child (`TOGI_SWEEP=1`) are visible to the child's hooks (verified in both SessionStart and SessionEnd of the child).
- Blocking Stop-hook `reason` text is always user-visible.

**Prompt cache (verified; one observation under re-verification)**

- Cache TTL is 5 minutes from last use, refreshed every turn (an hour-long active session sweeps warm; only idle-then-quit goes cold) and model-scoped (a Haiku sweep can never read an Opus/Fable cache). **Under re-verification:** 1-hour-TTL cache writes observed — see [§3](#3-cost-model).

**Detaching the background sweep**

- `nohup … &` + `disown` is not enough: Claude Code reads hook stdout to EOF before releasing exit, and the backgrounded subshell inherits the hook's pipes. The subshell must redirect its own stdio (`</dev/null >/dev/null 2>&1`) **and** `disown` (Claude Code waitpids children). Regression-tested with a read-to-EOF harness.

**CLI flag hazards (verified)**

- `--allowedTools` / `--disallowedTools` are variadic — they consume the next positional as a tool name, silently swallowing a positional prompt. Deliver the prompt via stdin. (This argv/stdin bug was diagnosed via the `TOGI_DEBUG=1` log — see [§5](#5-activation--opt-in) and Troubleshooting in the README.)
- `--disallowedTools "Bash,…"` (one comma-separated arg) denies even when allow rules match (deny overrides allow), at the permission layer only (cache preserved). `--disallowedTools "*"` is a silent no-op. See [§4](#4-privacy--security) for the full lockdown rationale.

**Distribution (verified)**

- The installed CLI resolves a pinned `sha` plugin source as documented — a live `/plugin install` and a subsequent pin-bump update both delivered the pinned commit and ran its code. See [§8](#8-supply-chain--releases).

**Docs-sourced, NOT live-verified**

- The `SessionEnd` `reason` value table ([§1](#1-architecture--lifecycle)) — [hooks reference](https://code.claude.com/docs/en/hooks).
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
