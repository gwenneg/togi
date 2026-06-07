---
name: setup
description: Install togi — session hooks that capture AI friction events and remind developers to improve context docs
allowedTools:
  - Bash(awk *)
  - Bash(bash *)
  - Bash(chmod *)
  - Bash(curl *)
  - Bash(echo *)
  - Bash(grep *)
  - Bash(jq *)
  - Bash(mkdir *)
  - Bash(mktemp *)
  - Bash(mv *)
  - Bash(rm *)
  - Bash(shasum *)
  - Bash(sha256sum *)
  - Bash(uname *)
---

# Instructions

## Phase 1: Explain and get consent

Output the following text verbatim before taking any other action:

> **Togi** (研ぎ, to sharpen) is a friction-driven feedback loop for AI context docs. At the end of each session, a hook asks a small model to scan the transcript for friction events — corrections, clarifications, mistakes, tool denials — and writes them to `.claude/friction/`. Once enough sessions accumulate, a startup reminder prompts the team to run `/togi:update-context-docs`, which turns those events into doc improvements via a pull request.
>
> **Before proceeding, read these two points carefully:**
>
> 1. **Data sent to the API.** Friction capture is opt-in (see below). When enabled, up to 200 KB of the conversation between the user and Claude is sent to the Anthropic API at the end of each session using the developer's existing Claude Code credentials. Tool call outputs (file contents, command output) are excluded, but anything discussed in the conversational text is included. Injected content in the transcript could produce friction events targeting arbitrary files — review the PR diff from `/togi:update-context-docs` carefully.
>
> 2. **Supply chain.** This phase downloads a pre-built binary from a GitHub release and verifies it in two steps: first using GitHub's artifact attestation (`gh attestation verify`) to prove the binary was produced by the togi CI workflow, then using a SHA-256 checksum for integrity. Do not install if either check fails.

Use `AskUserQuestion` to ask: **"Do you want to proceed with the installation?"** Options: **Yes, proceed** / **No, cancel**.

If the user selects No, stop.

## Phase 2: Download and verify the togi binary

Detect the current platform:

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[ "$ARCH" = "x86_64" ] && ARCH="amd64"
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
BINARY="togi-${OS}-${ARCH}"
echo "Platform: $OS/$ARCH — binary: $BINARY"
```

Fetch the latest release tag:

```bash
TAG=$(curl -fsSL https://api.github.com/repos/gwenneg/togi/releases/latest | jq -r '.tag_name')
if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  echo "Error: could not fetch latest release tag." >&2
  exit 1
fi
echo "Installing togi $TAG"
```

Download the binary and checksum file into a temporary directory:

```bash
TOGI_TMPDIR=$(mktemp -d)
BASE="https://github.com/gwenneg/togi/releases/download/${TAG}"

curl -fsSL "${BASE}/${BINARY}" -o "${TOGI_TMPDIR}/togi" || { rm -rf "$TOGI_TMPDIR"; exit 1; }
curl -fsSL "${BASE}/sha256sums.txt" -o "${TOGI_TMPDIR}/sha256sums.txt" || { rm -rf "$TOGI_TMPDIR"; exit 1; }
```

Verify the build attestation using `gh`. This proves the binary was produced by the togi
GitHub Actions release workflow, using the same trust anchor the developer already relies on
for GitHub access — no additional tool installation required:

```bash
if ! gh attestation verify "${TOGI_TMPDIR}/togi" --repo gwenneg/togi; then
  echo "Error: attestation verification failed." >&2
  rm -rf "$TOGI_TMPDIR"
  exit 1
fi

echo "Attestation OK"
```

Then verify the binary checksum against the now-trusted `sha256sums.txt`:

```bash
EXPECTED=$(awk -v bin="$BINARY" '$2==bin{print $1}' "${TOGI_TMPDIR}/sha256sums.txt")
if [ -z "$EXPECTED" ]; then
  echo "Error: no checksum entry found for ${BINARY}." >&2
  rm -rf "$TOGI_TMPDIR"
  exit 1
fi

if command -v sha256sum &>/dev/null; then
  ACTUAL=$(sha256sum "${TOGI_TMPDIR}/togi" | awk '{print $1}')
else
  ACTUAL=$(shasum -a 256 "${TOGI_TMPDIR}/togi" | awk '{print $1}')
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "Error: checksum verification failed for ${BINARY}." >&2
  echo "  Expected: $EXPECTED" >&2
  echo "  Actual:   $ACTUAL" >&2
  rm -rf "$TOGI_TMPDIR"
  exit 1
fi

echo "Checksum OK: $ACTUAL"
```

If either verification step fails, stop and report the error. Do not proceed.

Install the binary:

```bash
mkdir -p .claude/bin
mv "${TOGI_TMPDIR}/togi" .claude/bin/togi
chmod +x .claude/bin/togi
rm -rf "$TOGI_TMPDIR"
```

## Phase 3: Configure hooks, marketplace, and gitignore

Output the following text verbatim before taking any other action in this phase:

> This phase configures `.claude/settings.json` with the togi session hooks, marketplace
> registration, and plugin enablement, and updates `.gitignore` with the togi allowlist.
> All existing content is preserved.
>
> **Friction capture is disabled by default.** To enable it, run `/togi:enable` (personal)
> or add `"TOGI_ENABLED": "1"` to `.claude/settings.json` (team-wide). Each developer
> can always opt out with `/togi:disable`.
>
> You can also set `TOGI_SESSION_THRESHOLD` (default: `3`) to control how many sessions
> accumulate before the startup reminder appears.

Run:

```bash
.claude/bin/togi configure
```

Show the output to the user verbatim. If the command fails, stop and report the error.

## Phase 4: Commit and open a PR

Stage only these files:
- `.claude/bin/togi`
- `.claude/settings.json`
- `.gitignore`

Create a branch named `chore/setup-togi` (add `-2`, `-3`, etc. if it already exists).

Commit with message: `chore: set up togi ($(.claude/bin/togi version))`

Push and open a PR with a body that includes:

- What was installed: the togi binary, session hooks, marketplace registration, and plugin enablement
- Marketplace note: the togi plugin is now available in `/plugin` for all developers; skills (`/togi:update-context-docs`, `/togi:disable`) are enabled automatically via `enabledPlugins`
- Opt-in instruction: add `"TOGI_ENABLED": "1"` to `.claude/settings.json` (team) or `.claude/settings.local.json` (personal) to enable friction capture
- Opt-out instruction: run `/togi:disable` at any time
- Data notice: when enabled, up to 200 KB of conversation text is sent to the Anthropic API per session; tool call outputs are excluded; review `/togi:update-context-docs` PR diffs carefully before merging

Include the standard `Generated with Claude Code` footer.
