#!/usr/bin/env bash
# Stop hook — keeps the friction-capture directive (delivered by session-start.sh) salient.
# On growth it re-injects a short nudge; on compaction — which can drop the directive
# entirely, and which PostCompact cannot repair (it cannot inject context) — it re-injects
# the FULL directive. First turn just records a baseline (SessionStart already delivered it).

# No -e: best-effort. A failure must drop the nudge, never disrupt the turn.
set -uo pipefail

source "$(dirname "$0")/logging.sh"

log "stop.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0})"

# Opt-in gate: do nothing for developers who haven't enabled capture.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then
  log "stop.sh" "exit: not enabled (TOGI_ENABLED=${TOGI_ENABLED:-unset})"
  exit 0
fi

command -v jq &>/dev/null || { log "stop.sh" "exit: jq not on PATH"; exit 0; }

SESSION_ID="" TRANSCRIPT=""
{ read -r SESSION_ID; read -r TRANSCRIPT; } < <(jq -r '.session_id, .transcript_path')
[ -r "$TRANSCRIPT" ] || { log "stop.sh" "exit: transcript not readable ('$TRANSCRIPT')"; exit 0; }

# Current context size = input + cache-read + cache-creation of the most recent
# assistant usage block. Read from the TAIL (the usage is near the end), capped, so a
# large transcript never makes this hook slow enough to show a spinner.
CTX=$( { tail -r "$TRANSCRIPT" 2>/dev/null || tac "$TRANSCRIPT"; } | head -n 300 | while IFS= read -r _line; do
  _v=$(printf '%s' "$_line" | jq -r '
    (.message.usage // empty)
    | (.input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens)' 2>/dev/null)
  if [ -n "$_v" ] && [ "$_v" != "null" ]; then printf '%s' "$_v"; break; fi
done )
# No usage yet (first turn) → nothing to measure.
case "$CTX" in ''|*[!0-9]*) log "stop.sh" "exit: no usage block in transcript yet"; exit 0 ;; esac

# Per-session state: the context size at the last refresh.
STATE="${TMPDIR:-/tmp}/togi-refresh-${SESSION_ID}"
LAST=$(cat "$STATE" 2>/dev/null); case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac

# Decide the action: seed (first turn — SessionStart already delivered the directive),
# reinject (sharp drop = compaction may have dropped it → re-send the FULL directive), or
# nudge (grew past the threshold = directive buried but present → short salience nudge).
GROWTH_THRESHOLD=40000
_action=""
if [ "$LAST" -eq 0 ]; then _action="seed"
elif [ "$CTX" -lt "$((LAST * 60 / 100))" ]; then _action="reinject"
elif [ "$((CTX - LAST))" -gt "$GROWTH_THRESHOLD" ]; then _action="nudge"
fi

# additionalContext is a silent system reminder (not shown to the user). Stop does not
# inject plain stdout, so the JSON field is required.
case "$_action" in
  reinject)
    printf '%s' "$CTX" > "$STATE" 2>/dev/null
    DIRECTIVE=$(cat "${CLAUDE_PLUGIN_ROOT}/assets/prompts/friction-capture.md" 2>/dev/null)
    log "stop.sh" "reinject: ctx=${CTX} last=${LAST} (compaction — full directive)"
    [ -n "$DIRECTIVE" ] && jq -n --arg ctx "$DIRECTIVE" \
      '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$ctx}}'
    ;;
  nudge)
    printf '%s' "$CTX" > "$STATE" 2>/dev/null
    log "stop.sh" "nudge: ctx=${CTX} last=${LAST} (growth — salience refresh)"
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"Reminder: apply the togi friction-capture rule from your instructions — if this turn contained a correction (a knowably-wrong choice) or a clarification (a fact you lacked), including an error you caught yourself, record it under .togi/friction/pending/ before finishing."}}'
    ;;
  seed)
    printf '%s' "$CTX" > "$STATE" 2>/dev/null
    log "stop.sh" "seed: baseline ctx=${CTX} (SessionStart delivered the directive)"
    ;;
  *)
    log "stop.sh" "no refresh (ctx=${CTX} last=${LAST})"
    ;;
esac

exit 0
