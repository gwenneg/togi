# Togi design — friction capture approach

## Friction capture — alternatives considered

The core problem: detect friction events (corrections, clarifications, mistakes, tool denials) reliably, without taxing the session, at acceptable cost, with an honest privacy story. Each approach trades these off differently.

| # | Approach | Recall | Session UX | Cost/session | Extra API call | Complexity |
|---|---|---|---|---|---|---|
| 1 | CLAUDE.md import, per-message instructions *(v0.2)* | Low, unmeasurable | Invisible, but per-message attention tax | ~free | No | Minimal |
| 2 | Unconditional blocking Stop hook *(v0.3)* | Medium | **Prompt wall every turn** | ~$1+ (extra inference/turn) | No | Low |
| 3 | Conditional Stop hook (keyword grep on transcript) | Medium, keyword-blind | Occasional visible block | Low | No | Medium |
| 4 | `UserPromptSubmit` silent `additionalContext` | Low (advisory only) | Invisible | ~free | No | Low |
| 5 | Layered: hook-parsed denials + keyword fast path + once-per-session sweep | High | One visible block/session | Low | No | High |
| 6 | Per-turn Haiku classifier in Stop hook | High | Invisible, +latency every turn end | Medium | Yes, per turn | Medium |
| 7 | SessionEnd → headless `claude -p` over transcript (fresh context) | High | Invisible | Medium (full re-read, no cache) | Yes, per session | Medium |
| 8 | SessionEnd digest → sweep at next SessionStart | Medium-high | Work at top of next session | Low | No | Medium |
| 9 | **SessionEnd → `claude -p --resume --fork-session` sweep** *(v0.4, chosen)* | **High** | **Invisible** | **~$0.05–0.20 (warm cache)** | Yes, per session | Medium |

## Why each was rejected

**1. CLAUDE.md import** — detection rests on the model voluntarily interrupting its own task per message; standing instructions habituate, recall is unknown and unmeasurable, and capture interrupts the response to the very correction that triggered it. Its virtues (zero cost, zero API calls, dead simple) are why it shipped first.

**2. Unconditional Stop hook** — fixed the attention problem (just-in-time enforcement) but a blocking Stop hook's `reason` is user-visible by design: a 22-line prompt rendered every turn. Also the most expensive option — one extra inference per turn plus the reason accumulating in context.

**3. Conditional Stop hook** — keyword filters have a systematic blind spot: corrections that don't use correction words. Bounded misses, but a whole phrasing style stays invisible forever.

**4. UserPromptSubmit injection** — silent, but advisory-only at the moment of least hindsight; effectively approach 1 with better recency.

**5. Layered design** — best recall without API calls, but three mechanisms to maintain, and still one visible block per session. The complexity wasn't buying enough over 9.

**6. Per-turn Haiku classifier** — semantic recall with no UI noise, but adds latency to every turn end and N API calls per session; breaks the privacy claim N times instead of once.

**7. Fresh-context transcript analysis** — works, but pays full input price (no cache reuse) and reads a serialized transcript instead of inhabiting the conversation; strictly dominated by 9 once `--fork-session` was verified.

**8. Deferred sweep at next SessionStart** — the only high-recall option preserving "no out-of-session API calls"; kept as the documented fallback if the consent change proves unpopular. Costs: latency at the top of the next session, sweeps a digest rather than the live context, never runs if no next session.

**9. Resume sweep (chosen)** — full-session hindsight from the model that lived the session (verified: fork carries complete context, original transcript untouched), zero session noise, and the cheapest of the high-recall options because the warm prompt cache replays the session at ~0.1× input price. Trades away: one API call per session (consent + cost disclosure required), no sweep on crashed sessions, detached-process fragility.

## Key empirical facts (verified 2026-06-10)

- `claude -p --resume <id> --fork-session` carries full session context, returns a new session id, and leaves the original transcript byte-identical. Without `--fork-session`, the resume mutates the user's session (transcript grew 10 → 19 lines and reused the same session id). Fork is mandatory.
- SessionEnd fires for headless `-p` sessions too (`reason: "other"`) — the sweep child triggers the hook itself, so the recursion guard is load-bearing, not defensive.
- Env vars set on the spawned child (`TOGI_SWEEP=1`) are visible to the child's hooks (verified in both SessionStart and SessionEnd of the child).
- `nohup env … claude -p … &` detaches cleanly; the hook returns immediately.
- `--allowedTools` is a variadic flag: it consumes the next positional argument as a second tool name. A prompt passed as a positional after `--allowedTools` is silently swallowed, leaving `--resume` with no prompt, which falls into the "continue a deferred tool" code path and fails with "No deferred tool marker found". Deliver the prompt via stdin (`printf '%s' "$PROMPT" | claude …`) to avoid this.
- Prompt cache TTL is 5 minutes from last use (refreshed every turn — an hour-long active session sweeps warm; only idle-then-quit goes cold) and model-scoped (a Haiku sweep can never read an Opus/Fable cache).
- Blocking Stop-hook `reason` text is always user-visible.

## SessionEnd `reason` values (docs-sourced 2026-06-11 — NOT live-verified)

From the hooks documentation (code.claude.com/docs/en/hooks), unlike the facts above which were tested live: the SessionEnd payload's `reason` field takes one of `clear` (after `/clear`), `resume` (before the session is re-opened with `--resume`/`--continue`), `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other`. Only `other` is live-verified here (headless `-p` ends report it — see above).

The sweep skips two of these as non-final ends:

- `resume` — the session is not over; its real exit fires SessionEnd again. Sweeping on resume would bill twice and capture duplicate events for the same session.
- `bypass_permissions_disabled` — a mid-session mode change, not a termination.

Log live `reason` values (TOGI_DEBUG=1) before relying on any finer distinctions, and re-verify this table when CLI behavior changes.

## Cost model derivation (2026-06-12 — pricing arithmetic, not measured invoices)

The "$0.05–$0.20 per session" figure used in the README, the setup disclosure, and the plugin description derives as follows:

- A sweep replays the **entire session context as input** via `--resume --fork-session`; the capture prompt (~200 tokens) and the JSON output (hundreds of tokens) are negligible next to it.
- Warm prompt-cache reads bill at **~0.1× base input price** (https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
- Reference case: a **150K-token session at Opus-class pricing** ($5/MTok input → ~$0.50/MTok cache-read) ≈ **$0.08 per sweep**. The $0.05–$0.20 range stretches that across ~50K–300K-token sessions.
- Cold sweep = full input price = ~10× warm (~$0.75 at 150K on Opus). The Haiku fallback caps the cold case at cold-Haiku pricing ($1/MTok → ~$0.15 at 150K) — roughly cold-Opus ÷ 5, which is why session-end.sh falls back to Haiku rather than sweeping cold on the session's model.

Prices used (per MTok, input / ~cache-read; cached 2026-06-04): Opus 4.8 $5.00 / ~$0.50 · Sonnet 4.6 $3.00 / ~$0.30 · Haiku 4.5 $1.00 / ~$0.10 · Fable 5 $10.00 / ~$1.00.

Caveats: the range is **Opus-referenced** — sessions on cheaper models sweep cheaper, and a long **Fable 5** session can exceed it (~$1/MTok cache-read → ~$0.25 at 250K tokens). Subscription users draw plan limits, not dollars. When prices change, re-derive as `session tokens × cache-read price` and update the figure everywhere it appears (README Cost, setup Phase 1, `.claude/togi.md` template, plugin descriptions, the opt-in notice in session-start.sh).

## Sweep tool lockdown (verified 2026-06-11)

- Headless `claude -p` INHERITS permission allow rules from user/project/local settings: in a project whose settings allow `Bash(echo *)`, a plain `-p` session executed Bash without prompting. A prompt injection in swept session content could therefore run any pre-allowed command, unsupervised. The sweep needs zero tools, so all action-capable tools are denied.
- `--disallowedTools "Bash,Edit,Write,..."` (comma-separated, single arg) denies the listed tools even when settings allow rules match — deny overrides allow. It acts at the permission layer only, so the tool definitions in the API request are unchanged and the warm prompt cache is preserved.
- `--disallowedTools "*"` is a silent no-op: bare `*` matches no tool name (Bash still executed). Never use it.
- `--disallowedTools` is variadic like `--allowedTools` — same positional-prompt swallow hazard. Prompt stays on stdin; pass the deny list as one comma-separated argument.
- `--bare` is unsuitable: per CLI help it restricts auth to `ANTHROPIC_API_KEY`/`apiKeyHelper` (OAuth and keychain never read), which breaks subscription users; and settings files are not in its documented skip list, so it is not shown to bypass inherited allow rules anyway.
- `--tools ""` would remove tool definitions from the request — tool definitions are part of the cached prefix, so every sweep would run cold, breaking the cost model.
- Read/Glob/Grep are denied too (added 2026-06-11): the sweep needs zero tools, and injected session content could otherwise direct the sweep to read local secrets (`.env`, credentials) into an event `body` — which `update-context-docs` later pushes into a pull request, completing a slow exfiltration channel. WebFetch/WebSearch (the fast channels) were already denied. Docs-sourced, NOT live-verified: the permissions docs state deny rules apply to read-only tools even though those tools normally require no permission prompt.
- Known gap: the deny list covers built-in tools only. MCP tools auto-allowed by project settings (e.g. `enableAllProjectMcpServers`) are not covered — a bare `mcp__*` deny pattern is unverified, and `--strict-mcp-config` would drop MCP tool definitions from the request (cold cache for MCP-using sessions). Revisit if a verified blanket deny becomes available.

Re-verify these when CLI behavior changes.

## Doc targeting moved to aggregation time (decided 2026-06-13)

Through v0.4.x every swept event carried a required `doc_gap` — the sweep named the doc to fix. That asked the sweep for a judgment it is structurally unable to make: it runs with every tool denied (see Sweep tool lockdown), so it cannot see the repo's doc tree — the only docs it knows are those that happened to be in the session's context, and friction events exist precisely because the relevant knowledge was *not* in context. In the common case `doc_gap` was a guess: `CLAUDE.md` by default, or an invented path. Worse, `update-context-docs`' "only edit files that exist" rule silently dropped events with invented paths, and its cleanup phase then deleted the session file — erasing them permanently. A quiet recall hole at the last mile, after all the effort spent on capture recall. Per-event targeting also fragmented aggregation: two sessions naming different docs for the same root cause were grouped as unrelated.

The split now follows what each stage can actually know:

- **The sweep captures only what it alone knows.** `misleading_doc` (optional) names a doc only when that doc was in the session's context *and* contained wrong or outdated guidance — the one case where sweep-time identification is reliable (the sweep watched the doc mislead) and hard to reconstruct later from a one-paragraph `body`. Missing-knowledge events carry no doc field; the `body` is required to name the topic precisely instead.
- **`update-context-docs` decides placement.** It has everything the sweep lacks: repo visibility (the actual doc tree, current rather than capture-time — paths go stale), all events across sessions (root-cause grouping: one fix may serve many events, one event may need several docs, a new doc may be warranted), and the user in the loop reviewing proposed targets before any edit. It costs nothing extra — the skill already read every target file before editing.
- **Legacy `doc_gap` events** (pre-change friction files still on disk) are accepted as low-confidence hints, never binding targets.
- **Injection guardrail made explicit in the skill:** targets must be in-repo documentation files — never settings, code, CI, or hook files — regardless of what an event's `body` or hint field names. Event content derives from session transcripts (injectable); the PR-as-exfiltration channel is the same reason the sweep denies Read (see Sweep tool lockdown).

Trade-off accepted: placement judgment now concentrates in one interactive run instead of being spread across sweeps. That run is exactly where the user already reviews events (and the PR is reviewed again by the team), which is a better seat for that judgment than an unsupervised, tool-denied headless sweep.

## Sweep output hardening: schema gate + significance cap (decided 2026-06-13)

Two small guards on what a sweep can inject into the pipeline, shipped together:

**Schema gate (session-end.sh).** The hook used to write whatever JSON array the sweep returned. A malformed event — missing field, wrong type value, a bare string in the array — flowed into the friction file and surfaced as confusion at processing time, possibly weeks later and far from its cause. Now a jq filter keeps only objects carrying `type`/`slug`/`captured_by`/`body` as non-empty strings with `type` one of the four known values, and the drop count is logged (`TOGI_DEBUG=1`). `misleading_doc` is deliberately not checked — it is optional by design (see Doc targeting), so absence is legitimate. The same filter is reused for both the count and the file write, so the two cannot disagree. The optional-field schema made this *more* necessary, not less: once "field missing" is sometimes valid, only an explicit gate can tell valid-sparse from malformed. Covered by the regression test (malformed events in the fake sweep output must not reach the friction file).

**Significance cap (capture prompt).** One overzealous sweep could emit a dozen marginal events and instantly trip the threshold-5 startup reminder — and the reminder's credibility is a UX asset: it only works if it is rare and deserved. The prompt now allows at most the five most significant events, ordered most significant first. The cap bounds per-session noise; the ordering means a truncated review still sees the strongest events first. Five was chosen to match the default `TOGI_EVENT_THRESHOLD`: a single session can fill the reminder quota only with five genuinely significant events, which is exactly when firing immediately is correct.

## Feedback loop: processed-event archive + recurrence detection (decided 2026-06-13)

Togi's promise is "PR merged → agent reads better docs → fewer stumbles", but nothing ever verified the last arrow — and `update-context-docs`' cleanup phase actively destroyed the data needed to check, `rm`-ing friction files after processing. A gap recurring *after* its fix landed is the most valuable signal in the system (the rule is too weak, lives in a doc agents don't read, or the PR never merged) and was indistinguishable from a brand-new event.

Now `update-context-docs` archives instead of deletes: one file per run under `.claude/friction/archive/`, every event (excluded ones included) annotated with `processed_date`, `outcome` (`doc_updated`/`excluded`), `target_docs`, and `branch`. Before editing, the skill compares incoming event groups against the archive — semantically, by `slug` + `body`; slugs are model-generated per sweep, so string equality misses true matches — and flags:

- **Recurrence after fix** (`doc_updated`, event `date` > `processed_date`): the fix didn't take. Severity floor: medium; strengthen or relocate the previous rule instead of appending a near-duplicate. Caveat the skill is told about: a recurrence may just mean the fix PR hasn't merged yet.
- **Recurrence after exclusion**: previously dismissed as noise and came back — surfaced to the user as "probably real after all".

Design constraints honored:

- Pending and archived events live in sibling directories — `.claude/friction/pending/` (written by the sweep, counted by the session-start reminder) and `.claude/friction/archive/` (written at processing, read only by the recurrence check) — so every consumer reads exactly the directory it means. An earlier draft kept pending files at the friction root with a `processed/` subfolder, which made correctness hinge on every scan remembering `-maxdepth 1`; renamed 2026-06-13, pre-release, with no installed base, so no migration path is kept.
- `.gitignore`'s `/.claude/friction/` covers both directories: local history, never committed (same privacy posture as pending events).
- The archive write is a `Write` into protected `.claude` and therefore prompts once per run — accepted, not routed around (see Protected paths).
- Archive files older than ~2 months are pruned at cleanup. The window only needs to cover PR-merge lag plus a few sessions on the fixed docs — recurrence slower than that is indistinguishable from new friction — and the whole archive enters the skill's context every run, so retention is a context-bloat knob, not just disk hygiene.

Trade-off accepted: excluded events are no longer "acceptable losses" (the old cleanup wording) — they persist in the archive as history. That is the point: exclusion was a judgment, and the archive is what lets a wrong judgment be caught.

## Protected paths vs. skill permissions (docs-sourced 2026-06-12 — NOT live-verified)

`.claude` is on Claude Code's fixed protected-directories list (https://code.claude.com/docs/en/permission-modes#protected-paths). Writes to protected paths are **never auto-approved** in any mode except `bypassPermissions`, and the check runs **before** allow rules are evaluated — so neither `permissions.allow` in settings nor a skill's `allowed-tools` can pre-approve a write to `.claude/settings.json` or `.claude/settings.local.json`. The two files are treated identically. Rationale (theirs, and ours): settings define permissions, so nothing running under the permission system may rewrite them silently.

Consequences for togi:

- The settings writes in `/togi:enable`, `/togi:disable`, and `/togi:setup` **always prompt**. This is acceptable — the write toggles a consent flag, and the prompt puts that approval in front of exactly the right person at the right moment.
- `enable` and `disable` carry **no `allowed-tools`**: an allowlist cannot deliver promptless operation for skills whose whole job is a protected write, so it buys nothing there (removed 2026-06-12).
- `setup` keeps `allowed-tools` only for steps that pre-approval can actually serve: `Write`/`Read`/`Edit` for the non-protected files it commits (`.gitignore` and the CONTRIBUTING/README pointer — the adoption note `.claude/togi.md` is protected and prompts regardless), and the git/gh flow. Everything else was removed (2026-06-12): `Bash(mkdir*)`, `Bash(touch .claude/*)`, `Bash(mv .claude/*)`, and later `Bash(jq*)` (its only remaining use is the Phase 3 opt-in write to protected settings files) and `Bash(grep*)` (its only use was settings.json presence checks that no longer exist). A dead grant is worse than a prompt.
- Whether the check inspects Bash redirect targets (`> .claude/foo.tmp`) or `mv` side effects is undocumented. Togi deliberately does **not** rely on that either way — routing writes through a vehicle the checker might miss would be evading a safety feature via an undocumented gap.
- `setup` Phase 3 delegates the opt-in to the `enable` skill via the `Skill` tool (`Skill(togi:enable)` in allowed-tools; `enable` accepts `repo`/`all` arguments to skip its scope question), so the opt-in commands live in exactly one file. Docs-sourced: the Skill tool "executes a skill within the main conversation" and `Skill(name)` is the documented permission syntax — but skill-from-skill nesting behavior is NOT explicitly documented. Verify on the first live setup run.

## Activation model (revised 2026-06-12 — opt-in per developer)

`TOGI_ENABLED` defaults to **`0`**: an installed plugin is dormant — hooks exit immediately, no sweep, no files, no cost. Each developer opts in personally via `/togi:setup` (offered at the end) or `/togi:enable`, at one of two scopes, both uncommitted:

- **repo**: `env.TOGI_ENABLED = "1"` in `.claude/settings.local.json` — this repo only
- **global**: same key in `~/.claude/settings.json` — every repo for this user

**Why the reversal** (this section previously said enabled-by-default, decided 2026-06-11): `/plugin marketplace add` registers user-globally (`~/.claude/plugins/known_marketplaces.json` — there is no project-scoped form), and `/plugin install` defaults to **user scope**, so the hooks fire in every repo on the machine. Enabled-by-default therefore meant billing sweeps in unrelated repos and writing `.claude/friction/` files into repos whose `.gitignore` was never configured — an accidental-commit/leak hazard. Opt-in also makes install scope irrelevant: a user-scope install is safe because it is dormant everywhere the developer hasn't enabled it.

A repo-local `TOGI_ENABLED=0` overrides a global `1` — settings precedence is local > project > user (docs-sourced, NOT live-verified) — which is what keeps `/togi:disable` meaningful for global opt-ins. Both `/togi:enable` and `/togi:disable` ask for scope (this repo / all my repos); the same precedence cuts the other way too: a global `0` does **not** override repo-local `1`s, so repos opted in individually must be disabled individually — the disable skill's global output states this exception instead of over-promising.

**One-time notice:** in repos carrying the committed adoption note `.claude/togi.md` (see Team distribution below), SessionStart shows not-yet-opted-in developers a single notice (cost + `/togi:enable`) and drops a marker at `.claude/togi-notice-shown` (git-ignored by setup) so it never repeats. Repos without the adoption note stay completely silent — that is the guard against user-scope installs nagging in unrelated projects.

Still rejected, do not reintroduce:

- `TOGI_SWEEP_ENABLED` as a *committed project-level* consent flag (the v0.4-plan mechanism) — consent stays personal and uncommitted.
- `TOGI_MIN_TURNS` (skip sweeps for sessions below a turn threshold) — shipped in v0.4.0, removed in v0.4.5, stays out.

## Team distribution (decided 2026-06-12 — nothing executable in git)

`/togi:setup` commits **no** `extraKnownMarketplaces` and **no** `enabledPlugins`. Committed entries are the platform's documented team pattern ("Require marketplaces for your team"), and teammates do get a prompt at folder-trust — but the prompt's decline behavior is undocumented, hooks get no separate trust step, and even "dormant" hooks execute at every session boundary. Committing enablement would grant togi's author code execution on every teammate's machine *on their behalf*, which contradicts togi's own supply-chain posture (README): code lands on a machine only when its owner installs it.

Instead the repo carries an adoption note: `.claude/togi.md` (install commands + cost model; inert) plus a pointer section in `CONTRIBUTING.md`/`README.md`, with the setup PR as the team's review artifact. The adoption note doubles as the signal for the one-time opt-in notice. Trade-off accepted: adoption is three manual commands per developer instead of zero, and developers who never install the plugin see no in-product discovery at all — the pointer section carries that load.

## Remote friction pooling + CI processing (considered 2026-06-13 — deferred, not designed)

Idea: instead of accumulating friction on each dev's machine, push events to a remote branch and have a CI job process them. Recorded here for a later stage; nothing below is committed to.

It decomposes into two proposals with very different profiles — most of the benefit lives in the first, most of the cost in the second:

**(a) Pooling events remotely.** The strongest argument for togi-anything: the capture filter is "would this recur?", and the best evidence of recurrence is the same root cause hitting several developers — a signal that per-machine accumulation makes structurally invisible. Today three devs each sit at 2 events, nobody crosses the threshold of 5 (or worse, three PRs open for the same gap). Cross-dev pooling would make aggregation-time root-cause grouping work over the team's events, not one person's. It also stops friction rotting on machines of devs who ignore the reminder, survives laptop wipes, and serves multi-machine devs. Mechanically cheap: a dedicated ref/branch, one uniquely-named file per session, no merge conflicts.

**(b) Processing in CI.** Buys timeliness (no human has to remember), but conflicts with three load-bearing commitments:

- **Privacy.** Event `body` paragraphs are distilled session content; the current story is "nothing leaves your machine except your own API call". Pushing raw events publishes session-derived prose to everyone with repo read access — and bodies are already classified as an exfiltration channel (the reason the sweep denies Read; see Sweep tool lockdown). Auto-pushing at session end removes the *first* human gate (Phase 3 event review) at the most sensitive point. Sanitization cannot fix this: the body *is* the payload.
- **Consent.** Capture opt-in is personal and uncommitted, and the data stays personal. Team-visible friction is partly a record of a dev's own corrections — readable as performance telemetry. Sharing needs its own consent step, separate from capture.
- **Supply chain.** A CI processor means committing executable workflow config (which `/togi:setup` pointedly refuses to do), parking a long-lived org API key in CI secrets, and pointing an agent that has push/PR rights at injectable input — with no Phase 3 human review, leaving only PR-diff review *after* edits were steered. That is the same threat shape the sweep lockdown exists to prevent. It also shifts billing from personal plan limits to an org API account.

**If revisited, stage it so every step keeps a human gate:**

1. Event sharing as a **separate opt-in** with a plain "your events become visible to repo readers" disclosure; session-end pushes the friction file to the shared ref; decliners keep the local-only flow. Consider a pre-push review moment (e.g. push at next session start with a one-line notice) rather than a silent push at session end.
2. **Processing stays interactive**: `update-context-docs` reads the shared ref in addition to the local dir; any opted-in dev processes the team pool with the Phase 2/3 review intact. This captures essentially the full pooling benefit with zero new credentials and nothing executable in git.
3. CI, if any, is **inert**: a scheduled job that counts events on the friction ref and opens an issue at a team threshold ("23 events from 4 devs — run /togi:update-context-docs"). No API key, no agent, no injection surface; replaces the per-dev startup nag with a team-level one.

Full CI processing (agent edits docs unsupervised) stays rejected unless 1–3 prove insufficient — and the injectable-input + credentials − human-gate combination argues against it even then. Default posture if implemented: pooling off for open-source repos with external contributors; reasonable for private team repos.

## Distribution pinning (2026-06-11)

- The plugin `source` in `.claude-plugin/marketplace.json` is pinned to a full commit `sha`: `{"source": "github", "repo": "gwenneg/togi", "sha": "83fd179..."}`. A relative `"./."` source tracks whatever ref the marketplace catalog was fetched at (effectively `main`); the explicit `github` + `sha` source decouples the plugin code users run from `main`, so WIP on `main` does not reach users. A `sha` is chosen over a `ref` tag because it is immutable — a tag can be force-moved, a commit hash cannot. The matching tag (`v0.4.6`) is kept as a human-readable marker only; the pin resolves the sha.
- Auto-update is removed everywhere (marketplace.json, the setup skill's `extraKnownMarketplaces` write, README). With auto-update off, third-party marketplaces update only when the user explicitly updates the plugin — the deliberate-release boundary on the consumer side.
- Residual risk: the pin lives on `main`, so an attacker who controls `main` can rewrite the sha. Pinning buys deliberate releases + verifiability (git content-addressing fixes the bytes once the sha is set), not protection against branch/account compromise — that needs account and branch hardening.
- `version` is Claude Code's **update cache key** (resolution order: plugin.json `version` → marketplace entry `version` → source commit SHA). **`version` is deliberately omitted from `plugin.json`** so the identity falls back to the pinned source SHA — making the SHA both the integrity pin and the cache key. A release is then a **single** `sha` bump: it changes the identity (triggers the update) and fixes the code (integrity) at once, with no second knob to keep in sync. This was chosen over keeping an explicit `version` (which would force bumping both `version` and `sha` in lockstep every release — a drift footgun where SHA-only ships nothing and version-only ships stale code).
- Trade-off accepted: the in-tool plugin version is now a commit SHA rather than a friendly string (human-readable naming lives in git tags + GitHub Releases). **Unverified:** that changing a *pinned* SHA (version omitted) invalidates the cache and delivers new code — the docs' "commit SHA → updates on every commit" guidance is written for branch-tracked sources, not pinned SHAs. If a SHA bump turns out not to deliver updates on a target CLI, restore an explicit `version` and bump both per release. Record the verification result here.
- Unverified here: that the installed CLI resolves a pinned `sha` plugin source as documented. This came from the plugin-marketplace docs, not a local test. Verify with `/plugin install` before depending on it, and record the result here.
