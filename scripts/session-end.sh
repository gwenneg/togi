#!/usr/bin/env bash
# SessionEnd hook — resumes the ended session headlessly to sweep it for friction events.

# No -e: best-effort — the fallible calls that matter degrade explicitly (|| fallbacks),
# and an uncaught failure would fail silently anyway.
set -uo pipefail

source "$(dirname "$0")/logging.sh"

log "session-end.sh" "hook started (TOGI_ENABLED=${TOGI_ENABLED:-0} TOGI_HEADLESS=${TOGI_HEADLESS:-0})"

# Opt-in gate: TOGI_ENABLED defaults to 0 — an install must never bill sweeps by itself.
# See docs/internals.md#5-activation--opt-in for more details.
if [ "${TOGI_ENABLED:-0}" != "1" ]; then
  log "session-end.sh" "exit: not enabled (TOGI_ENABLED=${TOGI_ENABLED:-unset}) — opt in via /togi:enable"
  exit 0
fi

# Recursion guard: the headless sweep is itself a session whose end fires SessionEnd,
# so without this it chains infinitely.
# See docs/internals.md#1-architecture--lifecycle for more details.
if [ "${TOGI_HEADLESS:-0}" = "1" ]; then
  log "session-end.sh" "exit: recursion guard (TOGI_HEADLESS=1) — child session, skipping to prevent infinite sweep chain"
  exit 0
fi

# Check binaries now — the backgrounded launch discards output, so a missing binary
# there would fail invisibly.
for _bin in claude jq; do
  if ! command -v "$_bin" &>/dev/null; then
    log "session-end.sh" "exit: $_bin binary not found on PATH"
    exit 0
  fi
done

SESSION_ID="" TRANSCRIPT="" REASON=""
{ read -r SESSION_ID; read -r TRANSCRIPT; read -r REASON; } < <(jq -r '.session_id, .transcript_path, .reason')
log "session-end.sh" "payload parsed (session_id='$SESSION_ID' transcript_path='$TRANSCRIPT' reason='$REASON')"

# Skip non-final ends: resume and bypass_permissions_disabled aren't terminations —
# sweeping them would bill twice.
# See docs/internals.md#1-architecture--lifecycle for more details.
case "$REASON" in
  resume|bypass_permissions_disabled)
    log "session-end.sh" "exit: reason '$REASON' is not a final session end — skipping sweep"
    exit 0
    ;;
esac

# Validate: SESSION_ID is interpolated into --resume and the friction filename —
# reject anything that isn't a plain id.
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

# Warm cache (recent last turn) → resume on the session's model (~0.1x input); cold →
# Haiku fallback. Age computed in jq for portability.
# See docs/internals.md#3-cost-model for more details.
CACHE_STATE=$(tail -n 10 "$TRANSCRIPT" | jq -rs '
  [.[].timestamp | values]
  | if length > 0 and (last | now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) > 290
    then "cold" else "warm" end
' 2>/dev/null || echo "warm")
MODEL_ARGS=()
[ "$CACHE_STATE" = "cold" ] && MODEL_ARGS=(--model haiku)
log "session-end.sh" "cache=${CACHE_STATE} model_args='${MODEL_ARGS[*]:-<session default>}'"

# --fork-session: required, else the sweep appends to the user's session. Prompt via
# stdin (--disallowedTools is variadic and would swallow a positional prompt). Deny
# every tool — headless -p inherits settings' allow rules, so injected session content
# could run a pre-allowed command.
# See docs/internals.md#4-privacy--security for more details.
DENY_TOOLS="Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Read,Glob,Grep"
log "session-end.sh" "launching headless sweep (claude -p --resume $SESSION_ID --fork-session --output-format json --disallowedTools $DENY_TOOLS ${MODEL_ARGS[*]:-})"

(
  # trap HUP: nohup protects only claude, but this subshell writes events after claude
  # exits — without the trap a terminal-close HUP would lose them.
  trap '' HUP
  _out="$(mktemp "${TMPDIR:-/tmp}/togi-claude-out.XXXXXX")"
  _err="$(mktemp "${TMPDIR:-/tmp}/togi-claude-err.XXXXXX")"
  # --output-format json wraps output in a telemetry envelope (cost, usage); client-side
  # only, so the warm cache is unaffected.
  nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session \
    --output-format json \
    --disallowedTools "$DENY_TOOLS" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
    < "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md" >"$_out" 2>"$_err"
  _exit=$?
  log "session-end.sh" "claude exited with status $_exit"
  while IFS= read -r _line; do log "claude:error"    "$_line"; done < "$_err"
  while IFS= read -r _line; do log "claude:response" "$_line"; done < "$_out"

  # Envelope telemetry — every field optional (a crashed claude leaves a partial file).
  _is_error=$(jq -r '.is_error // false' "$_out" 2>/dev/null || echo "")
  _cost=$(jq -r '.total_cost_usd // empty' "$_out" 2>/dev/null || echo "")
  _cache_read=$(jq -r '.usage.cache_read_input_tokens // empty' "$_out" 2>/dev/null || echo "")
  _cache_creation=$(jq -r '.usage.cache_creation_input_tokens // empty' "$_out" 2>/dev/null || echo "")
  _duration=$(jq -r '.duration_ms // empty' "$_out" 2>/dev/null || echo "")
  _fork_id=$(jq -r '.session_id // empty' "$_out" 2>/dev/null || echo "")
  log "session-end.sh" "sweep telemetry: cost_usd=${_cost:-n/a} cache_read_tokens=${_cache_read:-n/a} cache_creation_tokens=${_cache_creation:-n/a} (predicted: $CACHE_STATE) duration_ms=${_duration:-n/a} fork_session=${_fork_id:-n/a} is_error=${_is_error:-n/a}"

  # .result holds the model's text as a JSON string; parse the events array from it,
  # degrading to [] on any failure.
  _events=$(jq '.result | fromjson? // []' "$_out" 2>/dev/null || echo '[]')
  _events="${_events:-[]}"

  # Schema gate: keep only events with the required fields and a known type; drop and
  # log malformed ones.
  # See docs/internals.md#7-processing-friction-into-docs for more details.
  _valid='if type == "array" then map(select(
      (type == "object")
      and ([.type, .captured_by, .body] | all(type == "string" and length > 0))
      and (.type | IN("correction", "clarification", "mistake", "denial"))
    )) else [] end'
  _total=$(printf '%s' "$_events" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)
  _count=$(printf '%s' "$_events" | jq "$_valid | length" 2>/dev/null || echo 0)
  _total="${_total:-0}"
  _count="${_count:-0}"
  log "session-end.sh" "sweep returned $_total event(s), $_count valid after schema gate"
  if [ "$_total" -gt "$_count" ]; then
    log "session-end.sh" "dropped $((_total - _count)) malformed event(s)"
  fi

  if [ "$_count" -gt 0 ]; then
    _friction_dir="${CLAUDE_PROJECT_DIR:-.}/.togi/friction/pending"
    mkdir -p "$_friction_dir"
    _file="${_friction_dir}/$(date +%Y%m%dT%H%M%S)-${SESSION_ID}.json"
    # One file per sweep: a date on each event (events regroup across sweeps) and an
    # optional per-sweep cost header.
    # See docs/internals.md#1-architecture--lifecycle for more details.
    printf '%s' "$_events" | jq --arg date "$(date +%Y-%m-%d)" --arg cost "$_cost" \
      "$_valid"' | (if $cost != "" then {sweep_cost_usd: ($cost | tonumber)} else {} end)
        + {events: map(. + {date: $date})}' > "$_file"
    log "session-end.sh" "wrote $_file ($_count event(s))"
  fi

  rm -f "$_out" "$_err"
) </dev/null >/dev/null 2>&1 &
# Detach: the stdio redirect above AND disown are both load-bearing — without them
# session exit blocks on the sweep.
# See docs/internals.md#1-architecture--lifecycle for more details.
disown $!
