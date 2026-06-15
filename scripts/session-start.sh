#!/usr/bin/env bash
# SessionStart hook — one-time opt-in notice for developers who haven't enabled togi,
# and a reminder to process accumulated friction once the event threshold is reached.

# No -e: this hook is best-effort — a failure should drop the reminder, not abort
# mid-script. set -u still catches unset-variable bugs.
set -uo pipefail

source "$(dirname "$0")/logging.sh"

log "session-start.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0} TOGI_HEADLESS=${TOGI_HEADLESS:-0})"

# Headless session launched by session-end.sh — a child sweep must produce no
# notices or reminders.
if [ "${TOGI_HEADLESS:-0}" = "1" ]; then
  log "session-start.sh" "exit: headless session (TOGI_HEADLESS=1) — suppressing output"
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Not opted in: show a one-time notice, but only in repos carrying the committed
# adoption note (.claude/togi.md) — a user-scope install fires this hook everywhere, so
# repos without the note must stay silent.
# See docs/internals.md#5-activation--opt-in for more details.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then

  if [ ! -f "$PROJECT_DIR/.claude/togi.md" ]; then
    log "session-start.sh" "exit: not enabled, repo has no togi adoption note — staying silent"
    exit 0
  fi

  MARKER="$PROJECT_DIR/.claude/togi-notice-shown"
  if [ -e "$MARKER" ]; then
    log "session-start.sh" "exit: not enabled, opt-in notice already shown"
    exit 0
  fi
  touch "$MARKER" 2>/dev/null
  log "session-start.sh" "showing one-time opt-in notice (marker: $MARKER)"
  # Static JSON — no jq dependency on this path.
  printf '%s\n' '{"systemMessage": "Togi is set up in this repo but off for you. Opt in with /togi:enable — one API call per session end (~$0.05–$0.20 at API rates, from your Agent SDK credit or API billing). This notice will not repeat."}'
  exit 0
fi

# jq required from here on — to count friction events and emit the JSON response.
if ! command -v jq &>/dev/null; then
  log "session-start.sh" "exit: jq not found on PATH — outputting error message"
  echo '{"systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

# Count pending events only; processed events move to the sibling archive/, read by
# update-context-docs and never counted here.
# See docs/internals.md#7-processing-friction-into-docs for more details.
FRICTION_DIR="$PROJECT_DIR/.claude/friction/pending"

# Sum events across all session files; a malformed file counts as 0, not an error.
EVENT_COUNT=0
while IFS= read -r _f; do
  _n=$(jq '.events | length' "$_f" 2>/dev/null || echo 0)
  EVENT_COUNT=$((EVENT_COUNT + _n))
done < <(find "$FRICTION_DIR" -name "*.json" 2>/dev/null)
log "session-start.sh" "friction event count: $EVENT_COUNT (threshold: ${TOGI_EVENT_THRESHOLD:-10})"

# The reminder fires once the count reaches the threshold (default 10).
if [ "$EVENT_COUNT" -lt "${TOGI_EVENT_THRESHOLD:-10}" ]; then
  log "session-start.sh" "threshold not reached — no reminder"
  exit 0
fi

TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
# Template: line 1 is the stat message; lines 2+ are the box, with printf padding the
# variable-width {{LINE}} to a fixed width.
RAW=$(sed -n "1s/{{EVENT_COUNT}}/$EVENT_COUNT/p" "$TEMPLATE")
LINE=$(printf '║  %-49.49s║' "$RAW")
SYSTEM_MESSAGE=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
log "session-start.sh" "threshold exceeded — injecting reminder (template: $TEMPLATE)"

log "session-start.sh" "outputting JSON response"
jq -n --arg msg "$SYSTEM_MESSAGE" '{hookSpecificOutput: {hookEventName: "SessionStart"}, systemMessage: $msg}'
