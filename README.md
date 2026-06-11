# togi (研ぎ)

> Sharpen AI context docs through friction.

Togi is a [Claude Code](https://claude.ai/code) plugin that captures the moments when an AI coding agent stumbles — corrections, clarifications, wrong assumptions, denied tool calls — and turns them into context doc improvements via pull requests.

Each of those stumbles is a **friction event**: a signal that the shared context docs failed. Togi captures them invisibly at session end, accumulates them silently, and reminds the team to process them when enough have built up. Processing means editing the docs that caused the friction, so the same mistake doesn't recur.

## How it works

```
session ends → session-end.sh → forked headless sweep → friction files written to .claude/friction/
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
2. Configure the marketplace entry, plugin enablement, and sweep consent flag in your project
3. Open a pull request with all changes committed

The SessionStart and SessionEnd hooks are part of the plugin itself and require no project-side configuration.

### After setup (team)

`/togi:setup` commits the configuration to `.claude/settings.json`. Any developer who pulls the repo gets the togi skills automatically — no manual step needed.

## Usage

### Disable friction capture

Friction capture is **enabled by default** — it affects everyone who uses Claude Code in this repo. To opt out personally:

```
/togi:disable
```

This sets `TOGI_ENABLED=0` in `.claude/settings.local.json` (not committed, not shared).

### Re-enable friction capture

```
/togi:enable
```

### Process friction events

When enough sessions have accumulated unprocessed friction, togi shows a reminder at startup. Run:

```
/togi:update-context-docs
```

The skill will:

1. Show you the accumulated friction events and let you exclude any that look like noise
2. Edit the target documentation files
3. Open a pull request with a friction metrics summary

## Configuration

All configuration is via environment variables, set in `.claude/settings.json` (team-wide) or `.claude/settings.local.json` (personal).

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `1` | Set to `0` to disable friction capture (personal: use `.claude/settings.local.json`) |
| `TOGI_EVENT_THRESHOLD` | `5` | Friction events before the startup reminder appears |

## Cost

At the end of each qualifying session, togi launches one headless `claude -p --resume --fork-session` call to sweep the session for friction events. This is billed to your Anthropic API account (or drawn from your subscription's usage limits).

**Typical cost: $0.05–$0.20 per session.** This low cost comes from the prompt cache: Claude Code refreshes the cache on every turn, and togi launches the sweep immediately at session end — so the session's tokens are replayed at roughly 10% of normal input price.

**The cache rule:** the prompt cache has a 5-minute TTL from the last exchange, refreshed every turn. An active hour-long session sweeps cheap. Only a session left idle more than ~4 minutes before quitting loses its cache — in that case togi uses a Haiku fallback (the cache is model-scoped; Haiku cannot read an Opus or Fable cache, and cold Haiku costs roughly one-fifth of cold Opus).

**Subscription users:** the sweep draws from your plan's usage limits rather than billing dollars.

## Privacy

The sweep resumes your session via `claude -p --resume --fork-session` on your own account. Your session transcript is not sent to any third party — the sweep runs as a headless Claude Code process under your own credentials, exactly as if you had resumed the session yourself. The original session transcript is left byte-identical after the fork.

Friction files are written locally to `.claude/friction/` (git-ignored). Any developer can opt out with `/togi:disable`.

**Known limitation:** sessions ended by crash or SIGKILL are not swept. Recurring doc gaps in those sessions will be caught on later sessions.

## Troubleshooting

**Sweep not running or writing no friction files?** Set `TOGI_DEBUG=1` in `.claude/settings.local.json` (`env` block) to write structured sweep logs to `.claude/togi.log` in the project directory. This is how the argv/stdin bug was diagnosed.

## Supply chain

Togi is distributed as a Claude Code plugin via a GitHub-hosted marketplace. Skills, hooks, and scripts are version-controlled in this repository. To verify what you have installed, inspect the source at [github.com/gwenneg/togi](https://github.com/gwenneg/togi).

See [docs/design.md](docs/design.md) for the design rationale and alternatives considered.

## Cutting a release

Push to `main`. The togi marketplace entry sets `autoUpdate: true`, so users receive changes automatically on their next Claude Code session.

**Note for existing users upgrading from v0.3.0:** v0.4.0 replaces per-turn capture with an end-of-session sweep that makes one API call per session (typically $0.05–$0.20). Capture is paused until a team member re-runs `/togi:setup` to opt in to the new cost model.

## License

[Apache 2.0](LICENSE)
