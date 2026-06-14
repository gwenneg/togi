#!/usr/bin/env bash
# SessionEnd hook — resumes the ended session headlessly to sweep it for friction events.

# No -e: failures are tolerated deliberately (every fallible call has an explicit
# fallback) and a hook that dies mid-script would fail silently in the background.
set -uo pipefail

# Logging must be set up first so every early exit can be recorded.
source "$(dirname "$0")/lib/logging.sh"

log "session-end.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0} TOGI_HEADLESS=${TOGI_HEADLESS:-0})"

# Opt-in gate: TOGI_ENABLED defaults to 0. `/plugin install` defaults to USER
# scope, i.e. hooks fire in every repo on the machine — an install must never
# start billing sweeps by itself. /togi:setup or /togi:enable writes the opt-in
# (see docs/design.md, Activation model).
if [ "${TOGI_ENABLED:-0}" != "1" ]; then
  log "session-end.sh" "exit: not enabled (TOGI_ENABLED=${TOGI_ENABLED:-unset}) — opt in via /togi:enable"
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
log "session-end.sh" "launching headless sweep (claude -p --resume $SESSION_ID --fork-session --output-format json --disallowedTools $DENY_TOOLS ${MODEL_ARGS[*]:-})"

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
  # --output-format json wraps the response in a result envelope carrying
  # measured sweep telemetry (total_cost_usd, usage). It is client-side
  # formatting only — the API request (prompt, tool definitions) is unchanged,
  # so the warm-cache property is unaffected. Verified 2026-06-13: the
  # envelope's cost reconciles exactly with this run's own usage at list
  # prices — a fork-resume does NOT import the resumed session's prior spend;
  # prior turns appear only as the input replay (see docs/design.md, Sweep
  # telemetry).
  nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session \
    --output-format json \
    --disallowedTools "$DENY_TOOLS" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    < "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md" >"$_out" 2>"$_err"
  _exit=$?
  log "session-end.sh" "claude exited with status $_exit"
  while IFS= read -r _line; do log "claude:error"    "$_line"; done < "$_err"
  while IFS= read -r _line; do log "claude:response" "$_line"; done < "$_out"

  # Envelope telemetry — every field optional: a crashed claude leaves an
  # empty or partial file, and total_cost_usd is unverified on auth modes
  # other than this account's. The prediction-vs-measured line is the
  # instrument for the cache-TTL question: a sweep predicted cold that shows
  # large cache reads proves the 290 s threshold too conservative.
  _is_error=$(jq -r '.is_error // false' "$_out" 2>/dev/null || echo "")
  _cost=$(jq -r '.total_cost_usd // empty' "$_out" 2>/dev/null || echo "")
  _cache_read=$(jq -r '.usage.cache_read_input_tokens // empty' "$_out" 2>/dev/null || echo "")
  _cache_creation=$(jq -r '.usage.cache_creation_input_tokens // empty' "$_out" 2>/dev/null || echo "")
  _duration=$(jq -r '.duration_ms // empty' "$_out" 2>/dev/null || echo "")
  _fork_id=$(jq -r '.session_id // empty' "$_out" 2>/dev/null || echo "")
  log "session-end.sh" "sweep telemetry: cost_usd=${_cost:-n/a} cache_read_tokens=${_cache_read:-n/a} cache_creation_tokens=${_cache_creation:-n/a} (predicted: $CACHE_STATE) duration_ms=${_duration:-n/a} fork_session=${_fork_id:-n/a} is_error=${_is_error:-n/a}"

  # The model's text lives in the envelope's .result as a string; extract and
  # parse the events array from it. Every failure degrades to zero events
  # (raw text already in the debug log above): missing/partial envelope,
  # is_error=true (.result is then an error message, not events), or a
  # disobedient model wrapping the array in prose.
  _events=$(jq '.result | fromjson? // []' "$_out" 2>/dev/null || echo '[]')
  _events="${_events:-[]}"

  # Write all qualifying events as a single JSON file — one file per session.
  # Bash adds session metadata; the update-context-docs skill reads JSON directly.
  # Schema gate: keep only events that carry the required capture fields as
  # non-empty strings and a known type. A malformed event written now would
  # surface as confusion at processing time, possibly weeks later — drop it
  # here and log it instead. misleading_doc is optional by design (see
  # assets/prompts/capture-friction.md), so its absence is not checked.
  _valid='if type == "array" then map(select(
      (type == "object")
      and ([.type, .captured_by, .body] | all(type == "string" and length > 0))
      and (.type | IN("correction", "clarification", "mistake", "denial"))
    )) else [] end'
  _total=$(printf '%s' "$_events" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)
  _count=$(printf '%s' "$_events" | jq "$_valid | length" 2>/dev/null || echo 0)
  # ${...:-0}: belt and braces against jq emitting nothing yet exiting 0.
  _total="${_total:-0}"
  _count="${_count:-0}"
  log "session-end.sh" "sweep returned $_total event(s), $_count valid after schema gate"
  if [ "$_total" -gt "$_count" ]; then
    log "session-end.sh" "dropped $((_total - _count)) malformed event(s)"
  fi

  if [ "$_count" -gt 0 ]; then
    _friction_dir="${CLAUDE_PROJECT_DIR:-.}/.claude/friction/pending"
    mkdir -p "$_friction_dir"
    _file="${_friction_dir}/$(date +%Y%m%dT%H%M%S)-${SESSION_ID}.json"
    # The file is one session's sweep. Each field lives where the skill
    # consumes it: the sweep date on every event (recurrence/display/PR all
    # operate per event, and events get regrouped across sweeps), the per-sweep
    # cost in the header (summed per sweep, not per event; only when the
    # envelope provided it). Richer telemetry (cache tokens, predicted
    # warm/cold) stays in the debug log — the skill never reads it.
    printf '%s' "$_events" | jq --arg date "$(date +%Y-%m-%d)" --arg cost "$_cost" \
      "$_valid"' | (if $cost != "" then {sweep_cost_usd: ($cost | tonumber)} else {} end)
        + {events: map(. + {date: $date})}' > "$_file"
    log "session-end.sh" "wrote $_file ($_count event(s))"
  fi

  rm -f "$_out" "$_err"
) </dev/null >/dev/null 2>&1 &
# Both halves of the detach are load-bearing (the stdio redirect was found
# missing 2026-06-13: session exit blocked for the sweep's full duration):
# - The stdio redirect above: Claude Code reads hook stdout until EOF, and the
#   backgrounded subshell inherits the hook's pipes — nohup only redirects
#   claude's own fds. An inherited write end delays EOF until the sweep ends.
#   The subshell's real output goes through log() to the log file.
# - disown: Claude Code waitpids child processes before releasing the session
#   exit; the job must leave the shell's job table.
disown $!
