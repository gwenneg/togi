#!/usr/bin/env bash
# SessionStart hook — reminds Claude to process accumulated friction when the event threshold is reached.

# Early exit: headless session launched by session-end.sh — showing a reminder to a
# non-interactive process makes no sense and would trigger another SessionEnd sweep.
[ "${TOGI_HEADLESS:-0}" = "1" ] && exit 0

# Early exit: developer opted out via TOGI_ENABLED=0 in .claude/settings.local.json.
[ "${TOGI_ENABLED:-1}" = "1" ] || exit 0

# Early exit: jq is required to parse stdin and produce valid JSON output.
if ! command -v jq &>/dev/null; then
  echo '{"systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

FRICTION_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/friction"
mkdir -p "$FRICTION_DIR"

SYSTEM_MESSAGE=""

# Count friction files and show a reminder once the threshold is reached.
EVENT_COUNT=$(find "$FRICTION_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
if [ "${EVENT_COUNT:-0}" -gt "${TOGI_EVENT_THRESHOLD:-5}" ]; then
  TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
  # Line 1 is the stat message; lines 2+ are the box with a {{LINE}} placeholder
  # for the one variable-width line built with printf for fixed 49-char padding.
  RAW=$(sed -n '1p' "$TEMPLATE" | sed "s/{{EVENT_COUNT}}/$EVENT_COUNT/g")
  LINE=$(printf '║  %-49.49s║' "$RAW")
  SYSTEM_MESSAGE=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
fi

jq -n --arg msg "$SYSTEM_MESSAGE" '{
  hookSpecificOutput: {hookEventName: "SessionStart"}
} + (if $msg != "" then {systemMessage: $msg} else {} end)'
