#!/bin/bash
# Stop hook — prompts Claude to capture friction events before stopping.

# Early exit: developer opted out via TOGI_ENABLED=0 in .claude/settings.local.json.
if [ "${TOGI_ENABLED:-1}" != "1" ]; then
  exit 0
fi

# Early exit: jq is required to parse stdin and produce valid JSON output.
if ! command -v jq &>/dev/null; then
  exit 0
fi

PAYLOAD=$(cat)

# Early exit: already continuing because of a Stop hook — prevent infinite loop.
if [ "$(echo "$PAYLOAD" | jq -r '.stop_hook_active // false')" = "true" ]; then
  exit 0
fi

SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // "unknown"')

FRICTION_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/friction"

REASON=$(sed "s|{{SESSION_ID}}|${SESSION_ID}|g; s|{{FRICTION_DIR}}|${FRICTION_DIR}|g" \
  "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md")

jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'
