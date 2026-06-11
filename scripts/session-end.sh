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

PROMPT=$(cat "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md")
log "session-end.sh" "prompt loaded (${#PROMPT} bytes)"

# --fork-session is REQUIRED (verified): without it the sweep is appended into the
# user's session history.
# Prompt must go via stdin — --allowedTools is variadic and swallows a trailing
# positional arg, producing a promptless --resume that fails with "No deferred tool found".
# No --allowedTools needed: the sweep outputs JSON; bash (not claude) writes the files.
log "session-end.sh" "launching headless sweep (claude -p --resume $SESSION_ID --fork-session ${MODEL_ARGS[*]:-})"

(
  _out="$(mktemp /tmp/togi-claude-out.XXXXXX)"
  _err="$(mktemp /tmp/togi-claude-err.XXXXXX)"
  printf '%s' "$PROMPT" | nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session \
    "${MODEL_ARGS[@]}" >"$_out" 2>"$_err"
  _exit=$?
  log "session-end.sh" "claude exited with status $_exit"
  while IFS= read -r _line; do log "claude:error"    "$_line"; done < "$_err"
  while IFS= read -r _line; do log "claude:response" "$_line"; done < "$_out"

  # Parse the JSON array and write one friction file per qualifying event.
  _count=$(jq 'if type == "array" then length else 0 end' "$_out" 2>/dev/null || echo 0)
  log "session-end.sh" "sweep returned $_count qualifying event(s)"

  if [ "$_count" -gt 0 ]; then
    _friction_dir="${CLAUDE_PROJECT_DIR:-.}/.claude/friction"
    mkdir -p "$_friction_dir"
    while IFS= read -r _ev; do
      _type=$(printf '%s' "$_ev"    | jq -r '.type        // "unknown"')
      _slug=$(printf '%s' "$_ev"    | jq -r '.slug        // "event"')
      _doc_gap=$(printf '%s' "$_ev" | jq -r '.doc_gap     // ""')
      _by=$(printf '%s' "$_ev"      | jq -r '.captured_by // "unknown"')
      _body=$(printf '%s' "$_ev"    | jq -r '.body        // ""')
      _file="${_friction_dir}/$(date +%Y%m%dT%H%M%S)-${_slug}.md"
      printf -- '---\ntype: %s\ndoc_gap: %s\ndate: %s\nsession: %s\ncaptured_by: %s\ncache: %s\n---\n\n%s\n' \
        "$_type" "$_doc_gap" "$(date +%Y-%m-%d)" "$SESSION_ID" "$_by" "$CACHE_STATE" "$_body" \
        > "$_file"
      log "session-end.sh" "wrote $_file"
    done < <(jq -c '.[]' "$_out" 2>/dev/null)
  fi

  rm -f "$_out" "$_err"
) &
