#!/usr/bin/env bash
# Stop hook — keeps the friction-capture directive (delivered by session-start.sh) salient.
# Every TOGI_REMINDER_INTERVAL turns it re-injects a short reminder via additionalContext.
# SessionStart resets the turn counter on every session event (startup, resume, clear,
# compact), so the interval is always relative to the most recent directive delivery.

set -euo pipefail

source "$(dirname "$0")/logging.sh"

log "stop.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0})"

# Opt-in gate: do nothing for developers who haven't enabled capture.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then
  log "stop.sh" "exit: not enabled (TOGI_ENABLED=${TOGI_ENABLED:-unset})"
  exit 0
fi

SESSION_ID=$(jq -r '.session_id')

# Per-session turn counter, reset to 0 by session-start.sh on every SessionStart event.
STATE="${TMPDIR:-/tmp}/togi-refresh-${SESSION_ID}"
TURNS=$(cat "$STATE" 2>/dev/null || true)
case "$TURNS" in ''|*[!0-9]*) TURNS=0 ;; esac
TURNS=$((TURNS + 1))

REMINDER_INTERVAL="${TOGI_REMINDER_INTERVAL:-10}"

if [ "$TURNS" -ge "$REMINDER_INTERVAL" ]; then
  printf '%s' "0" > "$STATE"
  log "stop.sh" "reminder: turn=${TURNS} interval=${REMINDER_INTERVAL} (counter reset)"
  # additionalContext injects into Claude's context as a system reminder; plain stdout
  # from Stop goes to the debug log only and is never seen by Claude.
  REMINDER=$(cat "${CLAUDE_PLUGIN_ROOT}/assets/prompts/stop.md")
  jq -n --arg ctx "$REMINDER" '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":$ctx}}'
else
  printf '%s' "$TURNS" > "$STATE"
fi

exit 0
