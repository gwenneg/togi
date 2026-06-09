#!/bin/bash
# Sets TOGI_ENABLED in .claude/settings.local.json.
# Usage: set-enabled.sh <0|1>
set -euo pipefail

VALUE="${1:?Usage: set-enabled.sh <0|1>}"
SETTINGS_LOCAL="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.local.json"

mkdir -p "$(dirname "$SETTINGS_LOCAL")"
[ -f "$SETTINGS_LOCAL" ] || echo '{}' > "$SETTINGS_LOCAL"
jq --arg v "$VALUE" '.env.TOGI_ENABLED = $v' "$SETTINGS_LOCAL" > "$SETTINGS_LOCAL.tmp" \
  && mv "$SETTINGS_LOCAL.tmp" "$SETTINGS_LOCAL"
