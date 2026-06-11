#!/usr/bin/env bash
# SessionEnd hook — resumes the ended session headlessly to sweep it for friction events.

# Logging must be set up first so every early exit can be recorded.
# shellcheck source=lib/logging.sh
source "$(dirname "$0")/lib/logging.sh"

log "session-end.sh" "hook started (TOGI_HEADLESS=${TOGI_HEADLESS:-0} TOGI_ENABLED=${TOGI_ENABLED:-1} TOGI_MIN_TURNS=${TOGI_MIN_TURNS:-3})"

# Recursion guard FIRST. SessionEnd fires for headless -p sessions too (verified) —
# removing this guard creates an infinite sweep chain.
if [ "${TOGI_HEADLESS:-0}" = "1" ]; then
  log "session-end.sh" "exit: recursion guard (TOGI_HEADLESS=1) — child session, skipping to prevent infinite sweep chain"
  exit 0
fi

if [ "${TOGI_ENABLED:-1}" != "1" ]; then
  log "session-end.sh" "exit: friction capture disabled (TOGI_ENABLED=${TOGI_ENABLED})"
  exit 0
fi

# Guard here, not at launch: the nohup'd launch discards output, so a missing
# binary there would fail invisibly in the background.
if ! command -v claude >/dev/null; then
  log "session-end.sh" "exit: claude binary not found on PATH"
  exit 0
fi
if ! command -v jq >/dev/null; then
  log "session-end.sh" "exit: jq binary not found on PATH"
  exit 0
fi

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // ""')
TRANSCRIPT=$(echo "$PAYLOAD" | jq -r '.transcript_path // ""')
log "session-end.sh" "payload parsed (session_id='${SESSION_ID:-<empty>}' transcript_path='${TRANSCRIPT:-<empty>}')"

if [ -z "$SESSION_ID" ]; then
  log "session-end.sh" "exit: session_id is empty"
  exit 0
fi
if [ ! -f "$TRANSCRIPT" ]; then
  log "session-end.sh" "exit: transcript not found at '$TRANSCRIPT'"
  exit 0
fi

# Skip trivial sessions — this is also the cost guard.
TURNS=$(jq -rs '[.[] | select(.type == "user")] | length' "$TRANSCRIPT" 2>/dev/null || echo 0)
log "session-end.sh" "transcript has $TURNS user turn(s), threshold is ${TOGI_MIN_TURNS:-3}"
if [ "$TURNS" -lt "${TOGI_MIN_TURNS:-3}" ]; then
  log "session-end.sh" "exit: session too short ($TURNS < ${TOGI_MIN_TURNS:-3} turns) — no sweep, no cost"
  exit 0
fi

# Prompt cache TTL is 5 min from the LAST exchange and is MODEL-SCOPED.
# Warm (recent last turn): resume on the session's model — input replays at ~0.1x price.
# Cold (idle-then-quit): the cache is lost to every model, so sweep on Haiku —
# cold Haiku ($1/MTok) beats cold Opus ($5) / Fable ($10). Do NOT "simplify" this
# to always-Haiku: a Haiku sweep can never read a warm Opus cache.
# Age is computed in jq (portable) — no BSD/GNU date parsing.
AGE=$(jq -rs '
  [.[].timestamp | values] | if length > 0
    then (last | now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | floor)
    else 0
    end
' "$TRANSCRIPT" 2>/dev/null || echo 0)
MODEL_ARGS=()
CACHE_STATE="warm"
[ "$AGE" -gt 240 ] && MODEL_ARGS=(--model haiku) && CACHE_STATE="cold"
log "session-end.sh" "session age=${AGE}s cache=${CACHE_STATE} model_args='${MODEL_ARGS[*]:-<session default>}'"

# {{CACHE}} is templated by the hook (it made the staleness decision);
# captured_by is self-reported by the sweep, which knows its own resolved model id.
PROMPT=$(sed -e "s|{{SESSION_ID}}|${SESSION_ID}|g" \
             -e "s|{{TIMESTAMP}}|$(date +%Y%m%dT%H%M%S)|g" \
             -e "s|{{DATE}}|$(date +%Y-%m-%d)|g" \
             -e "s|{{CACHE}}|${CACHE_STATE}|g" \
  "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md")
log "session-end.sh" "prompt templated (${#PROMPT} bytes)"

# --fork-session is REQUIRED (verified): without it the sweep is appended into the
# user's session history. nohup + & so quitting Claude Code is never delayed.
#
# Prompt must go via stdin, never as a positional arg after --allowedTools.
# --allowedTools is variadic: a trailing positional is consumed as a second tool name,
# leaving --resume with no prompt at all, which falls into the "continue a deferred tool"
# code path and fails with "No deferred tool marker found".
log "session-end.sh" "launching headless sweep (claude -p --resume $SESSION_ID --fork-session ${MODEL_ARGS[*]:-} --allowedTools Write(${CLAUDE_PROJECT_DIR:-.}/.claude/friction/**))"

if [ "$LOG" != "/dev/null" ]; then
  # Debug mode: capture claude stdout/stderr separately so each line can be tagged
  # with its source in the log. Runs in a subshell so the hook returns immediately.
  (
    _out="$(mktemp /tmp/togi-claude-out.XXXXXX)"
    _err="$(mktemp /tmp/togi-claude-err.XXXXXX)"
    printf '%s' "$PROMPT" | nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session \
      "${MODEL_ARGS[@]}" --allowedTools "Write(${CLAUDE_PROJECT_DIR:-.}/.claude/friction/**)" \
      >"$_out" 2>"$_err"
    _exit=$?
    log "session-end.sh" "claude exited with status $_exit"
    while IFS= read -r _line; do log "claude:response" "$_line"; done < "$_out"
    while IFS= read -r _line; do log "claude:error"    "$_line"; done < "$_err"
    rm -f "$_out" "$_err"
  ) &
else
  printf '%s' "$PROMPT" | nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session \
    "${MODEL_ARGS[@]}" --allowedTools "Write(${CLAUDE_PROJECT_DIR:-.}/.claude/friction/**)" >/dev/null 2>&1 &
fi
