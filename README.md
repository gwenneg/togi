# togi (研ぎ)

> Sharpen AI context docs through friction.

Togi is a [Claude Code](https://claude.ai/code) plugin that captures the moments when an AI coding agent stumbles — corrections, clarifications, wrong assumptions, denied tool calls — and turns them into context-doc improvements via pull requests.

Each stumble is a **friction event**: a signal that the shared context docs failed. Togi captures them in-session as they happen, accumulates them silently, and reminds the developer who hits the threshold to process them. Processing means editing the docs that caused the friction, so the same mistake doesn't recur — and the fix lands as a pull request the whole team reviews.

## How it works

```
you work → model hits friction → writes a note to .togi/friction/pending/   (denied tool calls: recorded by a hook)
                                                  ↓
               a Stop hook keeps the capture directive salient as context grows
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
- [jq](https://jqlang.org/) on PATH
- A way for Claude to open pull requests on your behalf — the [`gh` CLI](https://cli.github.com/) (authenticated with `gh auth login`), a GitHub [MCP server](https://code.claude.com/docs/en/mcp), or the GitHub HTTP API with a token

## Install

Togi is distributed as a Claude Code [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) — no cloning or file editing. In Claude Code:

```
/plugin marketplace add gwenneg/claude-ichiba
/plugin install togi@claude-ichiba
/reload-plugins
/togi:setup
```

`/togi:setup` explains what togi does, commits an inert adoption note as a reviewable PR (**nothing executable** — see [Team adoption](docs/internals.md#6-team-adoption--distribution)), and offers to enable capture for you.

Togi is **dormant by default**: `TOGI_ENABLED` defaults to `0`, so the hooks stay inert and no directive is delivered — nothing is captured until you opt in. A user-scope install (Claude Code's default) therefore stays silent in every repo where you haven't enabled it.

## Usage

**Enable / disable capture** — opt-in is per developer, at your choice of scope (this repo, or all your repos), and never committed:

```
/togi:enable      # turn on friction capture
/togi:disable     # turn it back off
```

**Process accumulated friction** — when enough events pile up, a startup reminder appears. Run:

```
/togi:update-context-docs
```

The skill groups events by root cause, proposes which docs to fix, flags recurrences (fixes that didn't take), lets you exclude noise, edits the docs, and opens a PR with a friction-metrics summary.

## Configuration

`TOGI_ENABLED` is set per developer by `/togi:enable` in `.claude/settings.json` (global) or `.claude/settings.local.json` (this repo); `TOGI_EVENT_THRESHOLD` can be set in either.

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `0` | The only switch, **off by default**. `1` activates the capture hooks (the Stop-refresh and the denial recorder). A repo-local `0` overrides a global `1`. |
| `TOGI_EVENT_THRESHOLD` | `10` | Friction events before the startup reminder appears. |

## Cost

**Effectively free.** Capture runs inside your normal Claude Code session — the working model writes a short note when it hits friction, and a local hook records denied tool calls — so there is no separate API call and no meaningful added cost. (togi's original design used a billed end-of-session sweep; that is now a documented [alternative](docs/alternatives/09-session-end-resume-sweep.md), not the implementation. See [why inline capture](docs/internals.md#2-friction-capture-alternatives-considered).)

## Privacy & safety

Everything stays on your machine. Friction notes are written locally under `.togi/friction/` (git-ignored) and nothing is sent to any third party — capture happens in your own session under your own credentials. The capture directive ships in the plugin (`assets/prompts/session-start.md`) as plain, readable instructions, delivered into your session only when you've enabled togi; denied tool calls are recorded by a hook with no model involved. Doc edits never happen automatically — they only land through `/togi:update-context-docs`, which you review before it opens a PR. See [Privacy & security](docs/internals.md#4-privacy--security).

## Staying up to date

Auto-update is off and Claude Code sends no new-version notification — **watch this repo → Releases only**. To update ([plugin docs](https://code.claude.com/docs/en/discover-plugins)):

```
/plugin marketplace update             # refresh the catalog (picks up the new pinned commit)
/plugin update togi@claude-ichiba      # install at that commit
/reload-plugins                        # load the updated hook code
```

Releases are pinned to an immutable commit SHA so work-in-progress on `main` never reaches you. The full rationale — and why a plugin's security bar is closer to a software-update service than a library — is in [Supply chain & releases](docs/internals.md#8-supply-chain--releases).

## Troubleshooting

Capture not writing notes? First confirm `TOGI_ENABLED` is `1` (run `/togi:enable`) — the `SessionStart` hook injects the directive only when enabled. For hook logs, set `TOGI_DEBUG=1` in `.claude/settings.local.json` (`env` block) to write structured logs to `.togi/togi.log`.

## Going deeper

The [internals doc](docs/internals.md) is the topic-by-topic reference behind every decision:

- [Architecture & lifecycle](docs/internals.md#1-architecture--lifecycle) · [Friction capture: alternatives](docs/internals.md#2-friction-capture-alternatives-considered)
- [Cost model](docs/internals.md#3-cost-model) · [Privacy & security](docs/internals.md#4-privacy--security) · [Activation & opt-in](docs/internals.md#5-activation--opt-in)
- [Team adoption](docs/internals.md#6-team-adoption--distribution) · [Processing friction into docs](docs/internals.md#7-processing-friction-into-docs)
- [Supply chain & releases](docs/internals.md#8-supply-chain--releases) · [Future work](docs/internals.md#9-future-work) · [Verified facts](docs/internals.md#10-verified-empirical-facts)

## License

[Apache 2.0](LICENSE)
