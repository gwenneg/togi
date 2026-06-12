#!/usr/bin/env bash
# SessionEnd hook — resumes the ended session headlessly to sweep it for friction events.

# No -e: failures are tolerated deliberately (every fallible call has an explicit
# fallback) and a hook that dies mid-script would fail silently in the background.
set -uo pipefail

# Logging must be set up first so every early exit can be recorded.
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
for _bin in claude jq; do
  if ! command -v "$_bin" &>/dev/null; then
    log "session-end.sh" "exit: $_bin binary not found on PATH"
    exit 0
  fi
done

SESSION_ID="" TRANSCRIPT="" REASON=""
{ read -r SESSION_ID; read -r TRANSCRIPT; read -r REASON; } < <(jq -r '.session_id, .transcript_path, .reason')
log "session-end.sh" "payload parsed (session_id='$SESSION_ID' transcript_path='$TRANSCRIPT' reason='$REASON')"

# Sweep only true session ends. Two reason values are not ends (per the hooks docs):
#   resume — fires before `claude --resume`/`--continue` re-opens the session; the
#   session continues and its real exit fires SessionEnd again. Sweeping here would
#   bill twice and capture duplicate events.
#   bypass_permissions_disabled — a mid-session mode change, not a termination.
case "$REASON" in
  resume|bypass_permissions_disabled)
    log "session-end.sh" "exit: reason '$REASON' is not a final session end — skipping sweep"
    exit 0
    ;;
esac

# Validate before use: SESSION_ID is interpolated into --resume and the friction
# filename, so reject anything that isn't a plain id (also catches jq's "null"
# when the hook payload is malformed).
case "$SESSION_ID" in
  ""|null|*[!A-Za-z0-9-]*)
    log "session-end.sh" "exit: invalid session_id ('$SESSION_ID') — malformed hook payload"
    exit 0
    ;;
esac
if [ ! -r "$TRANSCRIPT" ]; then
  log "session-end.sh" "exit: transcript not readable ('$TRANSCRIPT')"
  exit 0
fi

# Prompt cache TTL is 5 min from the LAST exchange and is MODEL-SCOPED.
# https://platform.claude.com/docs/en/build-with-claude/prompt-caching
# Warm (recent last turn): resume on the session's model — input replays at ~0.1x price.
# Cold (idle-then-quit): the cache is lost to every model, so sweep on Haiku —
# cold Haiku ($1/MTok) beats cold Opus ($5) / Fable ($10). Do NOT "simplify" this
# to always-Haiku: a Haiku sweep can never read a warm Opus cache.
# Age is computed in jq (portable) — no BSD/GNU date parsing.
CACHE_STATE=$(tail -n 10 "$TRANSCRIPT" | jq -rs '
  [.[].timestamp | values]
  | if length > 0 and (last | now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) > 290
    then "cold" else "warm" end
' 2>/dev/null || echo "warm")
MODEL_ARGS=()
[ "$CACHE_STATE" = "cold" ] && MODEL_ARGS=(--model haiku)
log "session-end.sh" "cache=${CACHE_STATE} model_args='${MODEL_ARGS[*]:-<session default>}'"

# --fork-session is REQUIRED (verified): without it the sweep is appended into the
# user's session history.
# Prompt must go via stdin (redirected straight from the prompt file) — --allowedTools
# is variadic and swallows a trailing positional arg, producing a promptless --resume
# that fails with "No deferred tool found". The redirect also means a missing prompt
# file fails before claude executes: no promptless sweep is ever launched or billed.
# The sweep needs no tools (it outputs JSON; bash writes the files), but headless -p
# INHERITS permission allow rules from user/project/local settings (verified) — a
# prompt injection in the swept session content could run any pre-allowed command,
# unsupervised, after the user has quit. Deny rules override allow rules, so deny
# every tool: action tools, and Read/Glob/Grep too — an injected instruction could
# otherwise have the sweep read local secrets (.env, credentials) into an event
# `body`, which update-context-docs later pushes into a pull request. Denying acts
# at the permission layer only, so tool definitions (and the warm cache) are
# unchanged. Do NOT swap this for:
#   --disallowedTools "*"  — matches no tool, silently a no-op (verified)
#   --tools ""             — removes tool definitions from the API request, changing
#                            the cached prefix and forcing every sweep cold
#   --bare                 — auth becomes ANTHROPIC_API_KEY-only, breaking
#                            subscription (OAuth) users
DENY_TOOLS="Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Read,Glob,Grep"
log "session-end.sh" "launching headless sweep (claude -p --resume $SESSION_ID --fork-session --disallowedTools $DENY_TOOLS ${MODEL_ARGS[*]:-})"

(
  # Ignore SIGHUP: closing the terminal (or an ssh disconnect) sends HUP to the
  # whole process group. nohup below only protects claude — this subshell parses
  # the output and writes the friction file AFTER claude exits, so without the
  # trap a HUP kills the parser and the session's events are silently lost
  # (disown is not HUP protection; it only stops the parent shell forwarding it).
  trap '' HUP
  # ${TMPDIR:-/tmp}: respect the platform tmpdir — on macOS that is a per-user
  # 0700 directory, so session-derived sweep output isn't even listable by others.
  _out="$(mktemp "${TMPDIR:-/tmp}/togi-claude-out.XXXXXX")"
  _err="$(mktemp "${TMPDIR:-/tmp}/togi-claude-err.XXXXXX")"
  nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session \
    --disallowedTools "$DENY_TOOLS" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    < "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md" >"$_out" 2>"$_err"
  _exit=$?
  log "session-end.sh" "claude exited with status $_exit"
  while IFS= read -r _line; do log "claude:error"    "$_line"; done < "$_err"
  while IFS= read -r _line; do log "claude:response" "$_line"; done < "$_out"

  # Write all qualifying events as a single JSON file — one file per session.
  # Bash adds session metadata; the update-context-docs skill reads JSON directly.
  _count=$(jq 'if type == "array" then length else 0 end' "$_out" 2>/dev/null || echo 0)
  log "session-end.sh" "sweep returned $_count qualifying event(s)"

  # ${_count:-0}: jq emits nothing (yet exits 0) on empty input — e.g. claude
  # crashed or the prompt redirect failed — leaving _count an empty string.
  if [ "${_count:-0}" -gt 0 ]; then
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
