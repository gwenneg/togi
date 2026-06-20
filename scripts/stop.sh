#!/usr/bin/env bash
# Stop hook — keeps the friction-capture directive (delivered by session-start.sh) salient.
# Every TOGI_NUDGE_INTERVAL turns it re-injects a short nudge via additionalContext.
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

NUDGE_INTERVAL="${TOGI_NUDGE_INTERVAL:-10}"

if [ "$TURNS" -ge "$NUDGE_INTERVAL" ]; then
  printf '%s' "0" > "$STATE"
  log "stop.sh" "nudge: turn=${TURNS} interval=${NUDGE_INTERVAL} (counter reset)"
  # additionalContext injects into Claude's context as a system reminder; plain stdout
  # from Stop goes to the debug log only and is never seen by Claude.
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"Reminder: apply the togi friction-capture rule from your instructions — if this turn contained a correction (a knowably-wrong choice) or a clarification (a fact you lacked), including an error you caught yourself, record it under .togi/friction/pending/ before finishing."}}'
else
  printf '%s' "$TURNS" > "$STATE"
fi

exit 0
