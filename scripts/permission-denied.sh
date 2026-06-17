#!/usr/bin/env bash
# PermissionDenied hook — records a denied tool call as a friction event, with no model
# call. A denial is a high-confidence signal the docs failed to steer the agent.

# No -e: best-effort. A failure must never affect the (already-decided) denial.
set -uo pipefail

source "$(dirname "$0")/logging.sh"

log "permission-denied.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0})"

# Opt-in gate: TOGI_ENABLED defaults to 0.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then
  log "permission-denied.sh" "exit: not enabled (TOGI_ENABLED=${TOGI_ENABLED:-unset})"
  exit 0
fi

command -v jq &>/dev/null || { log "permission-denied.sh" "exit: jq not on PATH"; exit 0; }

# Read the payload once — multiple jq calls would each consume stdin, leaving the later
# ones empty.
PAYLOAD=$(cat)
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // "tool"')
# A compact, truncated view of the tool input for the event body.
INPUT=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input // {}) | tostring' 2>/dev/null | tr '\n' ' ' | cut -c1-200)

# Stable slug per (tool, input) so an identical recurring denial dedups to one file.
# cksum is POSIX-portable; the number just disambiguates filenames.
HASH=$(printf '%s' "${TOOL}|${INPUT}" | cksum | cut -d' ' -f1)
SLUG="denied-$(printf '%s' "$TOOL" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')-${HASH}"
log "permission-denied.sh" "denial parsed (tool='$TOOL' slug='$SLUG' input='$INPUT')"

DIR="${CLAUDE_PROJECT_DIR:-.}/.togi/friction/pending"
mkdir -p "$DIR" 2>/dev/null || { log "permission-denied.sh" "exit: cannot create $DIR"; exit 0; }
FILE="${DIR}/${SLUG}.md"

# One event per file (markdown). type: denial.
if {
  printf '# denial\n\n'
  printf 'The `%s` tool call was denied (input: `%s`). If this denial reflects a gap the context docs should prevent — the agent attempting something it should have known not to do here — capture the rule that would steer it away next time.\n' "$TOOL" "$INPUT"
} > "$FILE" 2>/dev/null; then
  log "permission-denied.sh" "wrote denial event $FILE (tool=$TOOL)"
else
  log "permission-denied.sh" "error: failed to write $FILE — denial not recorded"
fi

exit 0
