#!/bin/bash
# SessionStart hook — creates the session friction directory, syncs capture-friction.md,
# and reminds Claude to process accumulated friction when the threshold is reached.
# Disable with TOGI_ENABLED=0 in .claude/settings.local.json.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
FRICTION_DIR="$PROJECT_DIR/.claude/friction"
THRESHOLD="${TOGI_SESSION_THRESHOLD:-3}"
ENABLED="${TOGI_ENABLED:-1}"

if ! command -v jq &>/dev/null; then
  echo '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "Togi: jq is not installed — friction capture is inactive."}, "systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

if [ "$ENABLED" != "1" ]; then
  jq -n '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: "Togi friction capture is inactive (TOGI_ENABLED=0). Do not write friction files."}}'
  exit 0
fi

SESSION_ID=$(jq -r '.session_id // "unknown"')

# Count before creating the current session dir so the count isn't inflated.
SESSION_COUNT=$(find "$FRICTION_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
EVENT_COUNT=$(find "$FRICTION_DIR" -mindepth 2 -maxdepth 2 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

mkdir -p "$FRICTION_DIR/$SESSION_ID"
echo "$SESSION_ID" > "$FRICTION_DIR/active-session"

MSG=""

PLUGIN_INSTR="${CLAUDE_PLUGIN_ROOT}/assets/capture-friction.md"
PROJECT_INSTR="$PROJECT_DIR/.claude/capture-friction.md"
if [ -f "$PLUGIN_INSTR" ] && { [ ! -f "$PROJECT_INSTR" ] || ! cmp -s "$PLUGIN_INSTR" "$PROJECT_INSTR"; }; then
  cp "$PLUGIN_INSTR" "$PROJECT_INSTR"
  MSG="Togi updated capture-friction.md — please commit .claude/capture-friction.md."
fi

if [ "${SESSION_COUNT:-0}" -ge "$THRESHOLD" ] && [ "${EVENT_COUNT:-0}" -gt 0 ]; then
  TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
  RAW=$(sed -n '1p' "$TEMPLATE" | sed "s/{{SESSION_COUNT}}/$SESSION_COUNT/g; s/{{EVENT_COUNT}}/$EVENT_COUNT/g")
  LINE=$(printf '║  %-49.49s║' "$RAW")
  REMINDER=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
  MSG="${MSG:+$MSG

}$REMINDER"
fi

jq -n --arg msg "$MSG" '{
  hookSpecificOutput: {hookEventName: "SessionStart"}
} + (if $msg != "" then {systemMessage: $msg} else {} end)'
