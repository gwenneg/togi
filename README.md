# togi (研ぎ)

> Sharpen AI context docs through friction.

Togi is a [Claude Code](https://claude.ai/code) plugin that captures the moments when an AI coding agent stumbles — corrections, clarifications, wrong assumptions, denied tool calls — and turns them into context doc improvements via pull requests.

Each of those stumbles is a **friction event**: a signal that the shared context docs failed. Togi captures them as they happen during each session, accumulates them silently, and reminds the team to process them when enough have built up. Processing means editing the docs that caused the friction, so the same mistake doesn't recur.

## How it works

```
end of each turn → Stop hook prompts Claude → friction event written to .claude/friction/
                                                ↓
next session start → session-start.sh → "12 friction events. Update the docs."
                                                ↓
developer runs /togi:update-context-docs → docs edited → PR opened
                                                ↓
PR merged → agent reads better docs → fewer stumbles next session
```

## Prerequisites

- [Claude Code](https://claude.ai/code)
- [gh CLI](https://cli.github.com/) — authenticated with `gh auth login`
- [jq](https://jqlang.org/)

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

1. Explain what togi does and ask for consent
2. Configure the marketplace entry and plugin enablement in your project
3. Open a pull request with all changes committed

The SessionStart and Stop hooks are part of the plugin itself and require no project-side configuration.

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

## Privacy

Claude detects and writes friction events directly to `.claude/friction/` during sessions as they occur. Nothing is sent to the Anthropic API on your behalf — the capture is done in-session by Claude itself, using observations from the conversation you are already having. Friction files are local and git-ignored. Any developer can opt out with `/togi:disable`.

## Supply chain

Togi is distributed as a Claude Code plugin via a GitHub-hosted marketplace. Skills, hooks, and scripts are version-controlled in this repository. To verify what you have installed, inspect the source at [github.com/gwenneg/togi](https://github.com/gwenneg/togi).

## Cutting a release

Push to `main`. The togi marketplace entry sets `autoUpdate: true`, so users receive changes automatically on their next Claude Code session.

## License

[Apache 2.0](LICENSE)
