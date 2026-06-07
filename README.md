# togi (研ぎ)

> Sharpen AI context docs through friction.

Togi is a [Claude Code](https://claude.ai/code) plugin that captures the moments when an AI coding agent stumbles — corrections, clarifications, wrong assumptions, denied tool calls — and turns them into context doc improvements via pull requests.

Each of those stumbles is a **friction event**: a signal that the shared context docs failed. Togi captures them automatically at the end of every session, accumulates them silently, and reminds the team to process them when enough have built up. Processing means editing the docs that caused the friction, so the same mistake doesn't recur.

## How it works

```
session ends → togi capture → friction events written to .claude/friction/
                                        ↓
next session start → togi remind → "5 sessions, 12 stumbles. Update the docs."
                                        ↓
developer runs /togi:update-context-docs → docs edited → PR opened
                                        ↓
PR merged → agent reads better docs → fewer stumbles next session
```

## Prerequisites

- [Claude Code](https://claude.ai/code)
- [gh CLI](https://cli.github.com/) — authenticated with `gh auth login`

## Installation

Run `/togi:setup` in Claude Code. The skill will:

1. Explain what togi does and ask for consent
2. Download the binary for your platform and verify it via `gh attestation verify` and SHA-256 checksum
3. Configure session hooks and the togi marketplace in `.claude/settings.json`
4. Open a pull request with the changes

To install the plugin, start Claude Code with the togi plugin directory or add it via the marketplace:

```bash
claude --plugin-dir /path/to/togi
```

Then run:

```
/togi:setup
```

## Usage

### Enable friction capture

Friction capture is **disabled by default** and personal — it only affects you, not the rest of the team.

```
/togi:enable
```

This sets `TOGI_ENABLED=1` in `.claude/settings.local.json` (not committed).

To enable it team-wide, add to `.claude/settings.json`:

```json
{
  "env": {
    "TOGI_ENABLED": "1"
  }
}
```

### Disable friction capture

```
/togi:disable
```

### Process friction events

When enough sessions have accumulated unprocessed friction, togi shows a reminder at startup. Run:

```
/togi:update-context-docs
```

The skill will:

1. Check if the togi binary needs updating
2. Show you the accumulated friction events and let you exclude any that look like noise
3. Edit the target documentation files
4. Open a pull request with a friction metrics summary

### Update togi

```
/togi:update-context-docs
```

The first phase checks for a newer binary and offers to install it. You can also trigger an update directly:

```bash
.claude/bin/togi install
```

## Configuration

All configuration is via environment variables, set in `.claude/settings.json` (team-wide) or `.claude/settings.local.json` (personal).

| Variable | Default | Description |
|---|---|---|
| `TOGI_ENABLED` | `0` | Set to `1` to enable friction capture |
| `TOGI_SESSION_THRESHOLD` | `3` | Sessions with unprocessed friction before the startup reminder appears |
| `TOGI_MAX_TRANSCRIPT_KB` | `200` | Max transcript size sent to the model for analysis |
| `TOGI_CAPTURE_MODEL` | `haiku` | Model used for friction analysis |

## Privacy

When friction capture is enabled, up to `TOGI_MAX_TRANSCRIPT_KB` KB of the conversation between you and Claude is sent to the Anthropic API at the end of each session, using your existing Claude Code credentials. Tool call outputs (file contents, command output) are excluded, but anything discussed in the conversational text is included.

Injected content in the transcript could produce friction events targeting arbitrary files. Review `/togi:update-context-docs` PR diffs carefully before merging.

## Supply chain

Togi binaries are built in CI, attested via [GitHub artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations), and verified on install with `gh attestation verify`. Checksums are generated and published alongside each release.

To verify a binary manually:

```bash
gh attestation verify .claude/bin/togi --repo gwenneg/togi
```

## Cutting a release

Push a version tag from the latest main:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The release workflow will:
1. Bump `plugin.json` to the new version and push to main
2. Build binaries for Linux and macOS (amd64 and arm64)
3. Attest all four binaries
4. Publish the GitHub release with binaries and `sha256sums.txt`

## License

[Apache 2.0](LICENSE)
