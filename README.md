# togi (研ぎ)

> Sharpen AI context docs through friction.

Togi is a [Claude Code](https://claude.ai/code) plugin that captures the moments when an AI coding agent stumbles — corrections, clarifications, wrong assumptions, denied tool calls — and turns them into context doc improvements via pull requests.

Each of those stumbles is a **friction event**: a signal that the shared context docs failed. Togi captures them invisibly at session end, accumulates them silently, and reminds the developer who hits the threshold to process them. Processing means editing the docs that caused the friction, so the same mistake doesn't recur — and the fix lands as a pull request the whole team reviews.

## How it works

```
session ends → session-end.sh → forked headless sweep → friction files written to .claude/friction/pending/
                                                                    ↓
                               next session start → session-start.sh → "12 friction events. Update the docs."
                                                                    ↓
                               developer runs /togi:update-context-docs → docs edited → PR opened
                                                                    ↓
                               PR merged → agent reads better docs → fewer stumbles next session
```

## Requirements

- macOS or Linux
- [Claude Code](https://claude.ai/code)
- [gh CLI](https://cli.github.com/) — authenticated with `gh auth login`
- [jq](https://jqlang.org/) on PATH

## Installation

Togi is distributed as a Claude Code marketplace — no cloning or file editing required.

In Claude Code, run:

```
/plugin marketplace add gwenneg/togi
```

This registers the togi marketplace. Then install the plugin:

```
/plugin install togi@togi
```

The togi skills (`/togi:setup`, `/togi:disable`, `/togi:enable`, `/togi:update-context-docs`) are now available. Run `/togi:setup` to finish configuration.

The setup skill will:

1. Explain what togi does, disclose the cost model, and ask for consent
2. Commit an adoption note — `.claude/togi.md` plus a `CONTRIBUTING.md`/`README.md` pointer — and the `.gitignore` entries; **nothing executable**
3. Offer to enable capture for you — this repo only, or all your repos
4. Open a pull request with all changes committed

The SessionStart and SessionEnd hooks are part of the plugin itself and require no project-side configuration. They are **dormant by default**: `TOGI_ENABLED` defaults to `0`, so nothing is captured, swept, or billed until you opt in — `/togi:setup` offers this at the end, or run `/togi:enable` at any time. Because the hooks do nothing unless you opted in, the plugin's install scope doesn't matter: a user-scope install (Claude Code's default) stays silent in every repo where you haven't enabled togi.

### After setup (team)

`/togi:setup` commits **no executable configuration** — no marketplace registration, no plugin enablement. It commits an adoption note: `.claude/togi.md` with the install commands and cost model, plus a pointer in `CONTRIBUTING.md` or `README.md`. Each developer installs togi deliberately (the same two `/plugin` commands above, then `/togi:enable`) — togi only ever lands on a machine whose owner installed it. Developers who already have the plugin get a one-time notice in repos that adopted togi, pointing them to `/togi:enable`; beyond that, nothing runs on their account without their say-so.

## Usage

### Enable friction capture (opt in)

Friction capture is **opt-in per developer** — nothing runs for you until you enable it:

```
/togi:enable
```

You choose the scope: **this repo only** (`TOGI_ENABLED=1` in `.claude/settings.local.json`) or **all your repos** (`~/.claude/settings.json`). Both are personal and never committed.

### Disable friction capture

```
/togi:disable
```

You choose the scope, mirroring enable: **this repo only** (`TOGI_ENABLED=0` in `.claude/settings.local.json` — this also overrides a global opt-in, for this repo only) or **all your repos** (`~/.claude/settings.json`). Both are personal and never committed. Note the one asymmetry: a global disable does not override repos where you opted in individually — disable those per repo.

### Process friction events

When enough sessions have accumulated unprocessed friction, togi shows a reminder at startup. Run:

```
/togi:update-context-docs
```

The skill will:

1. Group the accumulated friction events by root cause and propose the doc(s) where each fix belongs — placement is decided here, with full repo visibility, not by the sweep
2. Flag recurrences — events whose root cause an earlier run already fixed (the fix didn't take) or excluded as noise (it was probably real)
3. Let you exclude events that look like noise or redirect a proposed target
4. Edit (or create) the target documentation files
5. Open a pull request with a friction metrics summary, archiving the processed events locally (`.claude/friction/archive/`, git-ignored) so future runs can detect recurrences

## Configuration

All configuration is via environment variables, set in `.claude/settings.json` (team-wide) or `.claude/settings.local.json` (personal).

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `0` | The only switch, **off by default**. Set to `1` to activate friction capture — including the end-of-session sweep (one API call, billed or drawn from plan limits) — via `/togi:setup` or `/togi:enable` (repo scope: `.claude/settings.local.json`; global scope: `~/.claude/settings.json`). A repo-local `0` overrides a global `1` |
| `TOGI_EVENT_THRESHOLD` | `10` | Friction events before the startup reminder appears |

## Cost

At the end of each session, togi launches one headless `claude -p --resume --fork-session` call to sweep the session for friction events. This is drawn from your subscription's usage limits (or billed to your Anthropic API account). The sweep runs **only for developers who opted in** (`TOGI_ENABLED=1` via `/togi:setup` or `/togi:enable`) — an installed-but-unenabled plugin makes no API calls at all.

**Typical cost: $0.05–$0.20 per session.** This low cost comes from the prompt cache: Claude Code refreshes the cache on every turn, and togi launches the sweep immediately at session end — so the session's tokens are replayed at roughly 10% of normal input price.

**The cache rule:** the prompt cache has a 5-minute TTL from the last exchange, refreshed every turn. An active hour-long session sweeps cheap. Only a session whose last exchange is more than 290 seconds old at session end (just under the 5-minute TTL) is treated as cold — in that case togi uses a Haiku fallback (the cache is model-scoped; Haiku cannot read an Opus or Fable cache, and cold Haiku costs roughly one-fifth of cold Opus).

**Subscription users:** the sweep draws from your plan's usage limits rather than billing dollars.

**Measured, not just estimated:** each sweep records its actual cost (`sweep_cost_usd`) in the friction file it writes, and `/togi:update-context-docs` reports the summed sweep cost in its PR metrics — so the figures above are verifiable against your own data. (Cache-usage telemetry for the cost-model investigation goes to the debug log under `TOGI_DEBUG=1`, not the friction file.)

## Privacy

The sweep resumes your session via `claude -p --resume --fork-session` on your own account. Your session transcript is not sent to any third party — the sweep runs as a headless Claude Code process under your own credentials, exactly as if you had resumed the session yourself. The original session transcript is left byte-identical after the fork.

Friction files are written locally under `.claude/friction/` (`pending/`, then `archive/` once processed — both git-ignored). Any developer can opt out with `/togi:disable`.

**Known limitation:** sessions ended by crash or SIGKILL are not swept. Recurring doc gaps in those sessions will be caught on later sessions.

## Troubleshooting

**Sweep not running or writing no friction files?** Set `TOGI_DEBUG=1` in `.claude/settings.local.json` (`env` block) to write structured sweep logs to `.claude/togi.log` in the project directory. This is how the argv/stdin bug was diagnosed.

## Supply chain & publishing

A Claude Code plugin is not a passive dependency — installing it grants the author a **standing right to execute code on every user's machine**, at every session start and end, with no per-update review (Claude Code shows no diff and asks for no re-approval when plugin hooks change). Claude Code also has **no plugin signing, checksum, or integrity-verification step** in its install path. So the security bar for publishing togi is closer to *running a software-update service* than *shipping a library*. The publishing flow below is built around that fact.

### The model: two layers, each deliberately gated

Distribution has two independent layers, and with the choices togi makes, neither tracks "latest" automatically:

1. **The marketplace catalog** ([`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)) — fetched from `main` when a user adds the marketplace, and refreshed **only** when they explicitly run `/plugin marketplace update`. **Auto-update is off** (Claude Code's default for third-party marketplaces, which togi never overrides), so nothing refreshes it at startup.
2. **The plugin code** — the catalog pins the plugin `source` to a **full commit `sha`**:
   ```json
   "source": { "source": "github", "repo": "gwenneg/togi", "sha": "<40-char commit>" }
   ```
   Installing or updating togi fetches the plugin from that exact commit, not from `main`. Each release commit also carries a human-readable tag (e.g. [`v0.4.6`](https://github.com/gwenneg/togi/releases/tag/v0.4.6)) for reference, but the pin resolves the SHA, not the tag.

The consequence: **work-in-progress on `main` never reaches users.** A new version reaches them only when (a) the SHA pin is deliberately bumped *and* (b) they choose to refresh the catalog and update the plugin.

### Why this design (and why it's the strongest posture available)

The goal is three properties, in priority order:

- **No silent execution.** Auto-update would push whatever is on `main` to every user automatically — an un-recallable channel where a single bad commit (or a compromised account) becomes instant, unsupervised code execution everywhere. Turning auto-update off removes that channel: updates require a human decision on the user's side.
- **Tamper-evidence / verifiability.** Pinning to a commit `sha` rather than a branch or a tag means git's content-addressing fixes the exact bytes users run. A branch (`"./."`, the default) ships every commit; a tag (`ref`) can be force-moved; a **SHA cannot be moved or re-pointed**. Anyone can verify what they run by comparing the pinned SHA in `marketplace.json` against the repository history and inspecting the tree at that commit. This is the strongest integrity guarantee obtainable in a model where the consumer git-fetches source and the platform offers no signing.
- **Deliberate, reviewable releases.** Because the SHA bump is an explicit commit to `main`, every release is a single, auditable change rather than an implicit side effect of pushing code.

Given the platform's constraints (no plugin signing, hooks trusted implicitly, source fetched directly from git), **SHA-pin + auto-update-off is the most secure configuration available**: it strictly dominates the alternatives — a relative `"./."` source (tracks `main`, ships everything), a `ref`/tag pin (mutable), or auto-update on (silent) — on every one of the three properties above.

### Honest residual risks

This posture is not a complete defense, and the gaps point to complementary controls (tracked in [`docs/design.md`](docs/design.md)):

- **The pin lives on `main`.** Anyone who can write to `main` — via a compromised account or a merged malicious PR — can rewrite the SHA. Pinning gives deliberate releases and verifiability, **not** protection of `main` itself. That requires account hardening (hardware 2FA, no long-lived tokens), branch protection with required reviews and status checks, and signed commits/tags.
- **The catalog is an unpinned branch fetch.** When a user refreshes the catalog they pull `main`'s *current* `marketplace.json`, so a rewritten SHA is picked up on their next refresh. This is inherent to the catalog being the update channel; signed + protected `v*` tags and the SHA pin reduce, but do not eliminate, the exposure.
- **No update notifications.** Claude Code does not tell users when a new version exists (see [Staying up to date](#staying-up-to-date)).

### Cutting a release

Releases are deliberate — pushing to `main` does **not** ship code to users. `plugin.json` carries **no `version` field on purpose**, so the plugin's identity resolves to the pinned commit SHA. That makes the SHA do double duty — it is both the integrity pin *and* the update cache key — so a release is a **single bump** with no second knob to keep in sync:

1. Land all changes on `main`. The final commit is the release commit. If the plugin `description` changed, keep `plugin.json` and the `marketplace.json` plugin entry identical — nothing enforces it, and they drift otherwise.
2. Tag the release commit and push the tag (human-readable naming only — the pin resolves the SHA, not the tag):
   ```bash
   git tag -s vX.Y.Z -m "togi vX.Y.Z" && git push origin vX.Y.Z
   ```
   Prefer a **signed** tag (`-s`) and protect `v*` tags with a ruleset as hygiene.
3. Set `sha` in `.claude-plugin/marketplace.json` to the full 40-char SHA of the release commit, and commit it to `main`. **This single bump is the release**: changing the pinned SHA changes the plugin's identity (so Claude Code detects an update) *and* fixes the exact, immutable code users run (tamper-evidence).
4. Publish a [GitHub Release](https://github.com/gwenneg/togi/releases) with notes (`gh release create vX.Y.Z --generate-notes`) so users have a discovery signal and a changelog to evaluate the update against.

> **Verified 2026-06-13:** a pinned-SHA bump delivers updates. With `version` omitted, the plugin identity falls back to the source commit SHA, and bumping the pin then running `/plugin marketplace update` + `/plugin update togi@togi` moved an installed client to the new commit and ran the new code. Re-verify if a Claude Code update changes plugin resolution.

### Staying up to date

Because auto-update is off, Claude Code gives **no proactive notification** when a new version exists — so to find out, **watch this repository → Releases only** on GitHub. When a release is published, update in two steps:

```
/plugin marketplace update      # 1. refresh your local catalog from main — picks up the new pinned SHA
/plugin update togi@togi        # 2. install the plugin at that SHA
```

Step 1 is required: until you refresh the catalog, Claude Code has no knowledge that a newer release exists. Step 2 then installs the plugin at the commit the refreshed catalog pins. If Claude Code prompts you to reload afterward, run `/reload-plugins`.

**Note for existing users:** v0.4.0 replaced per-turn capture with an end-of-session sweep that makes one API call per session (typically $0.05–$0.20). As of the opt-in release, capture is **off by default**: after updating, nothing runs until you opt in with `/togi:enable` (or re-run `/togi:setup`).

## License

[Apache 2.0](LICENSE)
