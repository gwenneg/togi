#!/usr/bin/env bash
# SessionStart hook — reminds Claude to process accumulated friction when the event threshold is reached.

# Logging must be set up first so every early exit can be recorded.
# shellcheck source=lib/logging.sh
source "$(dirname "$0")/lib/logging.sh"

log "session-start.sh" "hook started (TOGI_HEADLESS=${TOGI_HEADLESS:-0} TOGI_ENABLED=${TOGI_ENABLED:-1})"

# Early exit: headless session launched by session-end.sh — showing a reminder to a
# non-interactive process makes no sense and would trigger another SessionEnd sweep.
if [ "${TOGI_HEADLESS:-0}" = "1" ]; then
  log "session-start.sh" "exit: headless session (TOGI_HEADLESS=1) — suppressing reminder"
  exit 0
fi

# Early exit: developer opted out via TOGI_ENABLED=0 in .claude/settings.local.json.
if [ "${TOGI_ENABLED:-1}" != "1" ]; then
  log "session-start.sh" "exit: friction capture disabled (TOGI_ENABLED=${TOGI_ENABLED})"
  exit 0
fi

# Early exit: jq is required to parse stdin and produce valid JSON output.
if ! command -v jq &>/dev/null; then
  log "session-start.sh" "exit: jq not found on PATH — outputting error message"
  echo '{"systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

FRICTION_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/friction"
mkdir -p "$FRICTION_DIR"
log "session-start.sh" "friction dir: $FRICTION_DIR"

SYSTEM_MESSAGE=""

# Count friction files and show a reminder once the threshold is reached.
EVENT_COUNT=$(find "$FRICTION_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
log "session-start.sh" "friction event count: $EVENT_COUNT (threshold: ${TOGI_EVENT_THRESHOLD:-5})"

if [ "${EVENT_COUNT:-0}" -gt "${TOGI_EVENT_THRESHOLD:-5}" ]; then
  TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
  # Line 1 is the stat message; lines 2+ are the box with a {{LINE}} placeholder
  # for the one variable-width line built with printf for fixed 49-char padding.
  RAW=$(sed -n '1p' "$TEMPLATE" | sed "s/{{EVENT_COUNT}}/$EVENT_COUNT/g")
  LINE=$(printf '║  %-49.49s║' "$RAW")
  SYSTEM_MESSAGE=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
  log "session-start.sh" "threshold exceeded — reminder injected (template: $TEMPLATE)"
else
  log "session-start.sh" "threshold not reached — no reminder"
fi

log "session-start.sh" "outputting JSON response"
jq -n --arg msg "$SYSTEM_MESSAGE" '{
  hookSpecificOutput: {hookEventName: "SessionStart"}
} + (if $msg != "" then {systemMessage: $msg} else {} end)'
