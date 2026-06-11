#!/usr/bin/env bash
# SessionEnd hook — resumes the ended session headlessly to sweep it for friction events.

# Logging must be set up first so every early exit can be recorded.
# shellcheck source=lib/logging.sh
source "$(dirname "$0")/lib/logging.sh"

log "session-end.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-1} TOGI_HEADLESS=${TOGI_HEADLESS:-0})"

if [ "${TOGI_ENABLED:-1}" != "1" ]; then
  log "session-end.sh" "exit: friction capture disabled (TOGI_ENABLED=${TOGI_ENABLED})"
  exit 0
fi

# Recursion guard. SessionEnd fires for headless -p sessions too (verified) —
# removing this guard creates an infinite sweep chain.
if [ "${TOGI_HEADLESS:-0}" = "1" ]; then
  log "session-end.sh" "exit: recursion guard (TOGI_HEADLESS=1) — child session, skipping to prevent infinite sweep chain"
  exit 0
fi

# Guard here, not at launch: the nohup'd launch discards output, so a missing
# binary there would fail invisibly in the background.
if ! command -v claude &>/dev/null; then
  log "session-end.sh" "exit: claude binary not found on PATH"
  exit 0
fi
if ! command -v jq &>/dev/null; then
  log "session-end.sh" "exit: jq binary not found on PATH"
  exit 0
fi

{ read -r SESSION_ID; read -r TRANSCRIPT; } < <(jq -r '.session_id, .transcript_path')
log "session-end.sh" "payload parsed (session_id='$SESSION_ID' transcript_path='$TRANSCRIPT')"

# Prompt cache TTL is 5 min from the LAST exchange and is MODEL-SCOPED.
# https://platform.claude.com/docs/en/build-with-claude/prompt-caching
# Warm (recent last turn): resume on the session's model — input replays at ~0.1x price.
# Cold (idle-then-quit): the cache is lost to every model, so sweep on Haiku —
# cold Haiku ($1/MTok) beats cold Opus ($5) / Fable ($10). Do NOT "simplify" this
# to always-Haiku: a Haiku sweep can never read a warm Opus cache.
# Age is computed in jq (portable) — no BSD/GNU date parsing.
CACHE_STATE=$(tail -n 5 "$TRANSCRIPT" | jq -rs '
  [.[].timestamp | values]
  | if length > 0 and (last | now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) > 290
    then "cold" else "warm" end
' 2>/dev/null || echo "warm")
MODEL_ARGS=()
[ "$CACHE_STATE" = "cold" ] && MODEL_ARGS=(--model haiku)
log "session-end.sh" "cache=${CACHE_STATE} model_args='${MODEL_ARGS[*]:-<session default>}'"

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

  # Write all qualifying events as a single JSON file — one file per session.
  # Bash adds session metadata; the update-context-docs skill reads JSON directly.
  _count=$(jq 'if type == "array" then length else 0 end' "$_out" 2>/dev/null || echo 0)
  log "session-end.sh" "sweep returned $_count qualifying event(s)"

  if [ "$_count" -gt 0 ]; then
    _friction_dir="${CLAUDE_PROJECT_DIR:-.}/.claude/friction"
    mkdir -p "$_friction_dir"
    _file="${_friction_dir}/$(date +%Y%m%dT%H%M%S)-${SESSION_ID}.json"
    jq --arg session "$SESSION_ID" --arg date "$(date +%Y-%m-%d)" --arg cache "$CACHE_STATE" \
      '[.[] | . + {session: $session, date: $date, cache: $cache}]' "$_out" > "$_file"
    log "session-end.sh" "wrote $_file ($_count event(s))"
  fi

  rm -f "$_out" "$_err"
) &
# Disown so the hook exits immediately. Without this, Claude Code waitpids on all
# child processes — including background jobs — before releasing the session exit,
# meaning the user would wait for the entire sweep to complete before quitting.
disown $!
