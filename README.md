# togi (研ぎ)

> Sharpen AI context docs through friction.

Togi is a [Claude Code](https://claude.ai/code) plugin that captures the moments when an AI coding agent stumbles — corrections, clarifications, wrong assumptions, denied tool calls — and turns them into context-doc improvements via pull requests.

Each stumble is a **friction event**: a signal that the shared context docs failed. Togi captures them invisibly at session end, accumulates them silently, and reminds the developer who hits the threshold to process them. Processing means editing the docs that caused the friction, so the same mistake doesn't recur — and the fix lands as a pull request the whole team reviews.

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
- [jq](https://jqlang.org/) on PATH
- A way for Claude to open pull requests on your behalf — the [`gh` CLI](https://cli.github.com/) (authenticated with `gh auth login`), a GitHub [MCP server](https://code.claude.com/docs/en/mcp), or the GitHub HTTP API with a token

## Install

Togi is distributed as a Claude Code [plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) — no cloning or file editing. In Claude Code:

```
/plugin marketplace add gwenneg/togi
/plugin install togi@togi
/reload-plugins
/togi:setup
```

`/togi:setup` explains what togi does, discloses the cost, commits an inert adoption note as a reviewable PR (**nothing executable** — see [Team adoption](docs/internals.md#6-team-adoption--distribution)), and offers to enable capture for you.

Togi is **dormant by default**: `TOGI_ENABLED` defaults to `0`, so nothing is captured, swept, or billed until you opt in. A user-scope install (Claude Code's default) therefore stays silent in every repo where you haven't enabled it.

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

Set in `.claude/settings.json` (team-wide) or `.claude/settings.local.json` (personal).

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `0` | The only switch, **off by default**. `1` activates capture, including the end-of-session sweep. A repo-local `0` overrides a global `1`. |
| `TOGI_EVENT_THRESHOLD` | `10` | Friction events before the startup reminder appears. |

## Cost

**Typically $0.05–$0.20 per session.** Each ended session triggers one headless `claude -p` sweep, billed at standard API rates — and **only if you opted in**. Headless usage draws from Anthropic's separate monthly [Agent SDK credit](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) (≈$20–$200 by plan, no rollover) rather than your general subscription limits; if it runs out, sweeps pause until it resets or you enable overflow billing. It's cheap because the sweep reuses the session's still-warm [prompt cache](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) (cache reads bill at ~0.1× input price); sessions left idle until the cache goes cold fall back to Haiku. Each sweep records its measured cost, so the figure is verifiable against your own data. See the [cost model](docs/internals.md#3-cost-model).

## Privacy & safety

The sweep resumes your session under your own credentials, exactly as if you had resumed it yourself — nothing goes to any third party, and your original transcript is left byte-identical. The sweep runs with [**all tools denied**](https://code.claude.com/docs/en/permissions), so injected session content can't run commands or read secrets. Friction files stay local under `.claude/friction/` (git-ignored). Sessions ended by crash or SIGKILL aren't swept; recurring gaps get caught on later sessions. See [Privacy & security](docs/internals.md#4-privacy--security).

## Staying up to date

Auto-update is off and Claude Code sends no new-version notification — **watch this repo → Releases only**. To update ([plugin docs](https://code.claude.com/docs/en/discover-plugins)):

```
/plugin marketplace update      # refresh the catalog (picks up the new pinned commit)
/plugin update togi@togi        # install at that commit
/reload-plugins                 # load the updated hook code
```

Releases are pinned to an immutable commit SHA so work-in-progress on `main` never reaches you. The full rationale — and why a plugin's security bar is closer to a software-update service than a library — is in [Supply chain & releases](docs/internals.md#8-supply-chain--releases).

## Troubleshooting

Sweep not running or writing no friction files? Set `TOGI_DEBUG=1` in `.claude/settings.local.json` (`env` block) to write structured logs to `.claude/togi.log`.

Sweeps failing or billing the wrong account? The sweep inherits your shell's credentials, and Claude Code ranks `ANTHROPIC_API_KEY` **above** your subscription login ([auth precedence](https://code.claude.com/docs/en/authentication.md#authentication-precedence)). So an exported `ANTHROPIC_API_KEY` silently bills sweeps to that key instead of the Agent SDK credit — and if the key is expired or from a disabled org, sweeps fail rather than falling back. Run `unset ANTHROPIC_API_KEY` (and check `claude` `/status`) to use your subscription. See the [cost model](docs/internals.md#which-account-gets-billed-ambient-anthropic_api_key).

## Going deeper

The [internals doc](docs/internals.md) is the topic-by-topic reference behind every decision:

- [Architecture & lifecycle](docs/internals.md#1-architecture--lifecycle) · [Why a session-end sweep](docs/internals.md#2-why-a-session-end-sweep-alternatives-considered)
- [Cost model](docs/internals.md#3-cost-model) · [Privacy & security](docs/internals.md#4-privacy--security) · [Activation & opt-in](docs/internals.md#5-activation--opt-in)
- [Team adoption](docs/internals.md#6-team-adoption--distribution) · [Processing friction into docs](docs/internals.md#7-processing-friction-into-docs)
- [Supply chain & releases](docs/internals.md#8-supply-chain--releases) · [Future work](docs/internals.md#9-future-work) · [Verified facts](docs/internals.md#10-verified-empirical-facts)

## License

[Apache 2.0](LICENSE)
</content>
