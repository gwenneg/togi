#!/usr/bin/env bash
# SessionStart hook — when enabled, injects the capture directive and (past the threshold)
# a reminder to process friction; otherwise shows a one-time opt-in notice in adopted repos.

# No -e: this hook is best-effort — a failure should drop the reminder, not abort
# mid-script. set -u still catches unset-variable bugs.
set -uo pipefail

source "$(dirname "$0")/logging.sh"

log "session-start.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0})"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Not opted in: show a one-time notice, but only in repos carrying the committed
# adoption note (adopt-togi.md) — a user-scope install fires this hook everywhere, so
# repos without the note must stay silent.
# See docs/internals.md#5-activation--opt-in for more details.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then

  if [ ! -f "$PROJECT_DIR/adopt-togi.md" ]; then
    log "session-start.sh" "exit: not enabled, repo has no togi adoption note — staying silent"
    exit 0
  fi

  MARKER="$PROJECT_DIR/.togi/togi-notice-shown"
  if [ -e "$MARKER" ]; then
    log "session-start.sh" "exit: not enabled, opt-in notice already shown"
    exit 0
  fi
  touch "$MARKER" 2>/dev/null
  log "session-start.sh" "showing one-time opt-in notice (marker: $MARKER)"
  # Static JSON — no jq dependency on this path.
  printf '%s\n' '{"systemMessage": "Togi is set up in this repo but off for you. Opt in with /togi:enable — togi then captures AI friction (corrections, clarifications, denied tool calls) as local notes you process into doc PRs. Capture runs inside your session at no extra cost. This notice will not repeat."}'
  exit 0
fi

# jq required from here on — to emit the JSON response (the reminder box needs escaping).
if ! command -v jq &>/dev/null; then
  log "session-start.sh" "exit: jq not found on PATH — outputting error message"
  echo '{"systemMessage": "Togi: jq is not installed. Install it to enable friction capture."}'
  exit 0
fi

# Count pending events only; processed events move to the sibling archive/, read by
# update-context-docs and never counted here. One markdown file = one event, so the
# count is just the number of pending files.
# See docs/internals.md#7-processing-friction-into-docs for more details.
FRICTION_DIR="$PROJECT_DIR/.togi/friction/pending"
EVENT_COUNT=$(find "$FRICTION_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
EVENT_COUNT=${EVENT_COUNT:-0}
log "session-start.sh" "friction event count: $EVENT_COUNT (threshold: ${TOGI_EVENT_THRESHOLD:-10})"

# Deliver the capture directive. This hook IS the delivery mechanism — the directive is
# never imported anywhere, so it reaches the model exactly when capture is enabled (this
# gated path). See docs/internals.md#1-architecture--lifecycle and alternative #10.
DIRECTIVE=$(cat "${CLAUDE_PLUGIN_ROOT}/assets/prompts/friction-capture.md" 2>/dev/null)
[ -n "$DIRECTIVE" ] || log "session-start.sh" "warning: directive asset empty/missing"

# The reminder (a user-visible systemMessage) is added only once the count reaches the
# threshold (default 10); the directive injection happens every enabled session.
SYSTEM_MESSAGE=""
if [ "$EVENT_COUNT" -ge "${TOGI_EVENT_THRESHOLD:-10}" ]; then
  TEMPLATE="${CLAUDE_PLUGIN_ROOT}/assets/reminders/$((RANDOM % 5 + 1)).md"
  # Template: line 1 is the stat message; lines 2+ are the box, with printf padding the
  # variable-width {{LINE}} to a fixed width.
  RAW=$(sed -n "1s/{{EVENT_COUNT}}/$EVENT_COUNT/p" "$TEMPLATE")
  LINE=$(printf '║  %-49.49s║' "$RAW")
  SYSTEM_MESSAGE=$(sed -n '2,$p' "$TEMPLATE" | sed "s|{{LINE}}|$LINE|")
  log "session-start.sh" "threshold reached — adding reminder (template: $TEMPLATE)"
fi

log "session-start.sh" "injecting directive${SYSTEM_MESSAGE:+ + reminder}"
jq -n --arg ctx "$DIRECTIVE" --arg msg "$SYSTEM_MESSAGE" '
  {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}
  + (if $msg != "" then {systemMessage: $msg} else {} end)'
