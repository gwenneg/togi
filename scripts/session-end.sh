#!/usr/bin/env bash
# SessionEnd hook — resumes the ended session headlessly to sweep it for friction events.

# Recursion guard FIRST. SessionEnd fires for headless -p sessions too (verified) —
# removing this guard creates an infinite sweep chain.
[ "${TOGI_HEADLESS:-0}" = "1" ] && exit 0
[ "${TOGI_ENABLED:-1}" = "1" ] || exit 0
# Guard here, not at launch: the nohup'd launch discards output, so a missing
# binary there would fail invisibly in the background.
command -v claude >/dev/null || exit 0
command -v jq >/dev/null || exit 0

PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // ""')
TRANSCRIPT=$(echo "$PAYLOAD" | jq -r '.transcript_path // ""')
[ -n "$SESSION_ID" ] || exit 0
[ -f "$TRANSCRIPT" ] || exit 0

# Skip trivial sessions — this is also the cost guard.
TURNS=$(jq -rs '[.[] | select(.type == "user")] | length' "$TRANSCRIPT" 2>/dev/null || echo 0)
[ "$TURNS" -ge "${TOGI_MIN_TURNS:-3}" ] || exit 0

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

# {{CACHE}} is templated by the hook (it made the staleness decision);
# captured_by is self-reported by the sweep, which knows its own resolved model id.
PROMPT=$(sed -e "s|{{SESSION_ID}}|${SESSION_ID}|g" \
             -e "s|{{TIMESTAMP}}|$(date +%Y%m%dT%H%M%S)|g" \
             -e "s|{{DATE}}|$(date +%Y-%m-%d)|g" \
             -e "s|{{CACHE}}|${CACHE_STATE}|g" \
  "${CLAUDE_PLUGIN_ROOT}/assets/prompts/capture-friction.md")

# --fork-session is REQUIRED (verified): without it the sweep is appended into the
# user's session history. nohup + & so quitting Claude Code is never delayed.
LOG=/dev/null
[ "${TOGI_DEBUG:-0}" = "1" ] && LOG=/tmp/togi-debug.log

nohup env TOGI_HEADLESS=1 claude -p --resume "$SESSION_ID" --fork-session "${MODEL_ARGS[@]}" \
  --allowedTools "Write(.claude/friction/**)" \
  "$PROMPT" >>"$LOG" 2>&1 &
