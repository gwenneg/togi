#!/bin/bash
# SessionStart hook — creates the session friction directory and injects the session
# path into Claude's context. Shows an ASCII reminder when enough friction has
# accumulated without being processed.
#
# Disable with TOGI_ENABLED=0 in .claude/settings.local.json.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
FRICTION_DIR="$PROJECT_DIR/.claude/friction"
THRESHOLD="${TOGI_SESSION_THRESHOLD:-3}"
ENABLED="${TOGI_ENABLED:-1}"

if ! command -v jq &>/dev/null; then
  echo '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "Togi: jq is not installed — friction capture is inactive."}, "systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Replace unsafe directory name characters with underscores, truncate to 64 chars.
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -cs 'a-zA-Z0-9_-' '_' | head -c 64)
[ -z "$SAFE_ID" ] && SAFE_ID="unknown"

if [ "$ENABLED" != "1" ]; then
  OUTPUT=$(jq -n '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: "Togi friction capture is inactive (TOGI_ENABLED=0). Do not write friction files."}}')
  echo "$OUTPUT"
  exit 0
fi

# Count accumulated sessions and events BEFORE creating the current session dir,
# so the off-session threshold is not inflated by the current (empty) session.
SESSION_COUNT=$(find "$FRICTION_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
EVENT_COUNT=$(find "$FRICTION_DIR" -mindepth 2 -maxdepth 2 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

# Create the session directory and update the active-session pointer (used as
# fallback by Claude if context compaction causes it to forget the session path).
mkdir -p "$FRICTION_DIR/$SAFE_ID"
echo "$SAFE_ID" > "$FRICTION_DIR/active-session"

OUTPUT=$(jq -n '{hookSpecificOutput: {hookEventName: "SessionStart"}}')

# Auto-update capture-friction.md when the plugin version changed or the project
# copy is missing (e.g. first clone after setup was committed by a teammate).
PLUGIN_INSTR="${CLAUDE_PLUGIN_ROOT}/assets/capture-friction.md"
PROJECT_INSTR="$PROJECT_DIR/.claude/capture-friction.md"
if [ -f "$PLUGIN_INSTR" ] && { [ ! -f "$PROJECT_INSTR" ] || ! cmp -s "$PLUGIN_INSTR" "$PROJECT_INSTR"; }; then
  cp "$PLUGIN_INSTR" "$PROJECT_INSTR"
  UPDATE_MSG="Togi updated capture-friction.md — please commit .claude/capture-friction.md."
  OUTPUT=$(echo "$OUTPUT" | jq --arg msg "$UPDATE_MSG" \
    'if .systemMessage then .systemMessage += "\n\n" + $msg else . + {systemMessage: $msg} end')
fi

if [ "${SESSION_COUNT:-0}" -ge "$THRESHOLD" ] && [ "${EVENT_COUNT:-0}" -gt 0 ]; then
  MESSAGES=(
    "${SESSION_COUNT} sessions. ${EVENT_COUNT} friction events. I counted.|The docs won't update themselves. (I've tried.)"
    "${SESSION_COUNT} sessions, ${EVENT_COUNT} stumbles. I'm not proud.|Update the docs. For both our sakes."
    "${SESSION_COUNT} sessions. ${EVENT_COUNT} friction events waiting.|Evidence suggests the docs need updating."
    "Good news: ${SESSION_COUNT} sessions of insights!|Bad news: ${EVENT_COUNT} events rotting in .claude/friction/."
    "ERROR: ${SESSION_COUNT} sessions, ${EVENT_COUNT} unprocessed friction events.|RECOMMENDED ACTION: update the docs. Please."
  )

  IDX=$((RANDOM % 5))
  IFS='|' read -r LINE1 LINE2 <<< "${MESSAGES[$IDX]}"

  # pad_line: wraps text in box-drawing border with 2 leading spaces, right-padded to 50 chars.
  pad_line() { printf '║  %-48.48s║' "$1"; }

  BORDER="══════════════════════════════════════════════════"
  EMPTY="║$(printf '%50s')║"

  SYSTEM_MSG=$(printf '\n╔%s╗\n║  %-48s║\n╠%s╣\n%s\n%s\n%s\n%s\n║  → /togi:update-context-docs                     ║\n%s\n║  Not your thing? Run /togi:disable.               ║\n╚%s╝' \
    "$BORDER" \
    "TOGI — FRICTION REMINDER" \
    "$BORDER" \
    "$EMPTY" \
    "$(pad_line "$LINE1")" \
    "$(pad_line "$LINE2")" \
    "$EMPTY" \
    "$BORDER")

  # Append to any existing systemMessage (e.g. the update notice above) rather than replacing it.
  OUTPUT=$(echo "$OUTPUT" | jq --arg msg "$SYSTEM_MSG" \
    'if .systemMessage then .systemMessage += "\n\n" + $msg else . + {systemMessage: $msg} end')
fi

echo "$OUTPUT"
