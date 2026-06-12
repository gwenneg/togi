#!/usr/bin/env bash
# SessionStart hook — one-time opt-in notice for developers who haven't enabled togi,
# and a reminder to process accumulated friction once the event threshold is reached.

# No -e: failures are tolerated deliberately (every fallible call has an explicit
# fallback) and a hook that dies mid-script would fail silently.
set -uo pipefail

# Logging must be set up first so every early exit can be recorded.
source "$(dirname "$0")/lib/logging.sh"

log "session-start.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0} TOGI_HEADLESS=${TOGI_HEADLESS:-0})"

# Early exit: headless session launched by session-end.sh — a child sweep must
# produce no notices or reminders.
if [ "${TOGI_HEADLESS:-0}" = "1" ]; then
  log "session-start.sh" "exit: headless session (TOGI_HEADLESS=1) — suppressing output"
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Opt-in gate: TOGI_ENABLED defaults to 0 (see docs/design.md, Activation model).
# Developers who haven't opted in get a single notice — only in repos carrying
# the committed adoption note .claude/togi.md (setup commits nothing executable;
# the adoption note is the "this repo uses togi" signal — see docs/design.md,
# Team distribution). A user-scope plugin install fires this hook in every repo
# on the machine; repos without the adoption note must stay silent.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then
  MARKER="$PROJECT_DIR/.claude/togi-notice-shown"
  if [ -e "$MARKER" ]; then
    log "session-start.sh" "exit: not enabled, opt-in notice already shown"
    exit 0
  fi
  if [ ! -f "$PROJECT_DIR/.claude/togi.md" ]; then
    log "session-start.sh" "exit: not enabled, repo has no togi adoption note — staying silent"
    exit 0
  fi
  touch "$MARKER" 2>/dev/null
  log "session-start.sh" "showing one-time opt-in notice (marker: $MARKER)"
  # Static JSON — no jq dependency on this path.
  printf '%s\n' '{"systemMessage": "Togi is set up in this repo but off for you. Opt in with /togi:enable — one API call per session end (~$0.05–$0.20, on your account or plan limits). This notice will not repeat."}'
  exit 0
fi

# Early exit: jq is required to count friction events and emit the JSON hook response.
if ! command -v jq &>/dev/null; then
  log "session-start.sh" "exit: jq not found on PATH — outputting error message"
  echo '{"systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

FRICTION_DIR="$PROJECT_DIR/.claude/friction"

# Count total events across all session JSON files.
EVENT_COUNT=0
while IFS= read -r _f; do
  _n=$(jq 'length' "$_f" 2>/dev/null || echo 0)
  EVENT_COUNT=$((EVENT_COUNT + _n))
done < <(find "$FRICTION_DIR" -maxdepth 1 -name "*.json" 2>/dev/null)
log "session-start.sh" "friction event count: $EVENT_COUNT (threshold: ${TOGI_EVENT_THRESHOLD:-5})"

# -lt: the reminder fires once the count REACHES the threshold (README: default 5).
if [ "$EVENT_COUNT" -lt "${TOGI_EVENT_THRESHOLD:-5}" ]; then
  log "session-start.sh" "threshold not reached — no reminder"
  exit 0
fi

TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
# Line 1 is the stat message; lines 2+ are the box with a {{LINE}} placeholder
# for the one variable-width line built with printf for fixed 49-char padding.
RAW=$(sed -n "1s/{{EVENT_COUNT}}/$EVENT_COUNT/p" "$TEMPLATE")
LINE=$(printf '║  %-49.49s║' "$RAW")
SYSTEM_MESSAGE=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
log "session-start.sh" "threshold exceeded — injecting reminder (template: $TEMPLATE)"

log "session-start.sh" "outputting JSON response"
jq -n --arg msg "$SYSTEM_MESSAGE" '{hookSpecificOutput: {hookEventName: "SessionStart"}, systemMessage: $msg}'
