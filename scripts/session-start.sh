#!/bin/bash
# SessionStart hook — reminds Claude to process accumulated friction when the event threshold is reached.
# Disable with TOGI_ENABLED=0 in .claude/settings.local.json.

if [ "${TOGI_ENABLED:-1}" != "1" ]; then
  echo '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "Togi friction capture is inactive. Do not write friction files."}}'
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "Togi friction capture is inactive. Do not write friction files."}, "systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

FRICTION_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/friction"
mkdir -p "$FRICTION_DIR"

SESSION_ID=$(jq -r '.session_id // "unknown"')
echo "$SESSION_ID" > "$FRICTION_DIR/active-session"

SYSTEM_MESSAGE=""

EVENT_COUNT=$(find "$FRICTION_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
if [ "${EVENT_COUNT:-0}" -gt "${TOGI_EVENT_THRESHOLD:-5}" ]; then
  TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
  RAW=$(sed -n '1p' "$TEMPLATE" | sed "s/{{EVENT_COUNT}}/$EVENT_COUNT/g")
  LINE=$(printf '║  %-49.49s║' "$RAW")
  SYSTEM_MESSAGE=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
fi

jq -n --arg msg "$SYSTEM_MESSAGE" '{
  hookSpecificOutput: {hookEventName: "SessionStart"}
} + (if $msg != "" then {systemMessage: $msg} else {} end)'
