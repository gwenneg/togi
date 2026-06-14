#!/usr/bin/env bash
# Regression test: session-end.sh must deliver the prompt via stdin, not as a positional arg,
# and must write friction files from the JSON output returned by claude (not from claude directly).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/session-end.sh"
# Verbatim string from assets/prompts/capture-friction.md — appears in every rendered prompt.
PROMPT_SENTINEL="Review this entire session for friction events"

PASS=0
FAIL=0
TEST_FAILURES=0

fail() { echo "  FAIL: $1"; TEST_FAILURES=$((TEST_FAILURES + 1)); }

run_test() {
  local name="$1" ts_age="$2" expect_haiku="$3"
  echo "--- $name ---"
  TEST_FAILURES=0

  local tmpdir; tmpdir="$(mktemp -d)"
  local fake_bin="$tmpdir/bin"
  mkdir -p "$fake_bin"
  local argv_file="$tmpdir/argv"
  local stdin_file="$tmpdir/stdin"

  # Fake claude: record argv and stdin, then emit a result envelope (as
  # --output-format json does) whose .result string holds one valid friction
  # event plus two malformed ones (unknown type; missing body) that the schema
  # gate in session-end.sh must drop. total_cost_usd must reach the friction
  # file header; the cache-token telemetry must NOT (debug-log only).
  cat > "$fake_bin/claude" << 'FAKE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TOGI_TEST_ARGV"
cat > "$TOGI_TEST_STDIN"
cat << 'ENVELOPE'
{"result":"[{\"type\":\"clarification\",\"misleading_doc\":\"CLAUDE.md\",\"captured_by\":\"test-model\",\"body\":\"Test body.\"},{\"type\":\"bogus\",\"captured_by\":\"test-model\",\"body\":\"x\"},{\"type\":\"correction\",\"captured_by\":\"test-model\"}]","total_cost_usd":0.0123,"usage":{"cache_read_input_tokens":4567,"cache_creation_input_tokens":890},"is_error":false,"duration_ms":1500,"session_id":"fork-session-id"}
ENVELOPE
FAKE_EOF
  chmod +x "$fake_bin/claude"

  # Sample transcript: ≥3 user entries with a controlled timestamp.
  local ts
  if [ "$ts_age" = "fresh" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  else
    ts="2020-01-01T00:00:00.000Z"
  fi
  local transcript="$tmpdir/transcript.jsonl"
  for i in 1 2 3; do
    printf '{"type":"user","timestamp":"%s","message":{"content":"turn %s"}}\n' "$ts" "$i" >> "$transcript"
  done

  local session_id="togi-test-abc123"
  local payload; payload="$(printf '{"session_id":"%s","transcript_path":"%s","reason":"prompt_input_exit"}' "$session_id" "$transcript")"

  # CLAUDE_PROJECT_DIR is set so the friction dir path is predictable.
  TOGI_TEST_ARGV="$argv_file" \
  TOGI_TEST_STDIN="$stdin_file" \
  PATH="$fake_bin:$PATH" \
  TOGI_ENABLED=1 \
  TOGI_HEADLESS=0 \
  TOGI_DEBUG=0 \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  CLAUDE_PROJECT_DIR="$tmpdir" \
    bash "$SCRIPT" <<< "$payload"

  # Wait up to 5 s for the fake claude to write its argv file.
  local i
  for i in $(seq 1 50); do
    [ -f "$argv_file" ] && break
    sleep 0.1
  done

  if [ ! -f "$argv_file" ]; then
    fail "fake claude never ran (timeout after 5 s)"
    FAIL=$((FAIL + 1))
    rm -rf "$tmpdir"
    return
  fi

  # Wait up to 5 s more for the subshell to parse JSON and write the friction file.
  for i in $(seq 1 50); do
    [ -n "$(find "$tmpdir/.claude/friction/pending" -name '*.json' 2>/dev/null | head -1)" ] && break
    sleep 0.1
  done

  # --- argv assertions ---
  grep -qx -- '-p'             "$argv_file" || fail "-p missing from argv"
  grep -qx -- '--resume'       "$argv_file" || fail "--resume missing from argv"
  grep -qx -- "$session_id"    "$argv_file" || fail "session_id missing from argv"
  grep -qx -- '--fork-session' "$argv_file" || fail "--fork-session missing from argv"
  # --allowedTools must NOT appear — claude no longer writes files directly.
  grep -qx -- '--allowedTools' "$argv_file" && fail "--allowedTools found in argv (should be absent)" || true
  # The sweep must deny all action-capable tools: headless -p inherits permission
  # allow rules from settings, and deny rules are the verified way to override them.
  grep -qx -- '--disallowedTools' "$argv_file" || fail "--disallowedTools missing from argv"
  grep -qx -- 'Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Read,Glob,Grep' "$argv_file" \
    || fail "deny list missing from argv"
  # The result envelope (telemetry + .result extraction) requires JSON output.
  grep -qx -- '--output-format' "$argv_file" || fail "--output-format missing from argv"
  grep -qx -- 'json'            "$argv_file" || fail "json missing from argv (--output-format value)"

  # --- stdin assertions ---
  # The prompt must NOT appear in argv (variadic swallow regression).
  grep -qF "$PROMPT_SENTINEL" "$argv_file" && fail "prompt text found in argv — variadic swallow bug" || true
  grep -qF "$PROMPT_SENTINEL" "$stdin_file" || fail "prompt sentinel missing from stdin"

  # --- model selection ---
  if [ "$expect_haiku" = "yes" ]; then
    grep -qx -- '--model' "$argv_file" || fail "--model missing from argv for cold session"
    grep -qx -- 'haiku'   "$argv_file" || fail "haiku missing from argv for cold session"
  else
    ! grep -qx -- '--model' "$argv_file" || fail "unexpected --model in argv for warm session"
  fi

  # --- friction file assertions ---
  local friction_file
  friction_file="$(find "$tmpdir/.claude/friction/pending" -name "*.json" 2>/dev/null | head -1)"
  [ -n "$friction_file" ] || fail "friction JSON file not created from sweep output"
  if [ -n "$friction_file" ]; then
    # Header: date + measured sweep cost only.
    jq -e '.date'                                     "$friction_file" >/dev/null 2>&1 || fail "date not in friction header"
    jq -e '.sweep_cost_usd == 0.0123'                 "$friction_file" >/dev/null 2>&1 || fail "sweep_cost_usd not stamped from envelope"
    # The removed fields must NOT be present.
    jq -e 'has("session")'                            "$friction_file" >/dev/null 2>&1 && fail "session should not be in friction header" || true
    jq -e 'has("cache")'                              "$friction_file" >/dev/null 2>&1 && fail "cache should not be in friction header" || true
    jq -e 'has("sweep_cache_read_tokens")'            "$friction_file" >/dev/null 2>&1 && fail "cache-token telemetry should not be stamped into the file" || true
    jq -e 'has("sweep_cache_creation_tokens")'        "$friction_file" >/dev/null 2>&1 && fail "cache-token telemetry should not be stamped into the file" || true
    # Events array: pure capture fields, schema-gated.
    jq -e '.events | length == 1'                     "$friction_file" >/dev/null 2>&1 || fail "schema gate did not drop the malformed events"
    jq -e '.events[0].type == "clarification"'        "$friction_file" >/dev/null 2>&1 || fail "wrong type in friction JSON"
    jq -e '.events[0].misleading_doc == "CLAUDE.md"'  "$friction_file" >/dev/null 2>&1 || fail "misleading_doc not passed through to friction JSON"
    jq -e '.events[0].body == "Test body."'           "$friction_file" >/dev/null 2>&1 || fail "body not in friction JSON"
    jq -e '.events[0] | has("slug") | not'            "$friction_file" >/dev/null 2>&1 || fail "slug should no longer be a capture field"
  fi

  rm -rf "$tmpdir"

  if [ "$TEST_FAILURES" -eq 0 ]; then
    echo "  PASS"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

run_test "warm session (no haiku)"       "fresh" "no"
run_test "cold session (haiku fallback)" "old"   "yes"

# Opt-in default: with TOGI_ENABLED unset, the hook must exit without ever
# invoking claude — an installed-but-unenabled plugin makes no API calls.
echo "--- opt-in default (TOGI_ENABLED unset → no sweep) ---"
TEST_FAILURES=0
tmpdir="$(mktemp -d)"
fake_bin="$tmpdir/bin"; mkdir -p "$fake_bin"
printf '#!/usr/bin/env bash\ntouch "$TOGI_TEST_RAN"\n' > "$fake_bin/claude"
chmod +x "$fake_bin/claude"
transcript="$tmpdir/transcript.jsonl"
printf '{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"content":"t"}}\n' > "$transcript"
payload="$(printf '{"session_id":"togi-test-optin","transcript_path":"%s","reason":"prompt_input_exit"}' "$transcript")"
TOGI_TEST_RAN="$tmpdir/ran" \
PATH="$fake_bin:$PATH" \
TOGI_HEADLESS=0 \
TOGI_DEBUG=0 \
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
CLAUDE_PROJECT_DIR="$tmpdir" \
  env -u TOGI_ENABLED bash "$SCRIPT" <<< "$payload"
sleep 1
[ -e "$tmpdir/ran" ] && fail "sweep launched despite TOGI_ENABLED unset (opt-in default broken)"
rm -rf "$tmpdir"
if [ "$TEST_FAILURES" -eq 0 ]; then
  echo "  PASS"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# Exit blocking: Claude Code reads the hook's stdout until EOF before
# releasing the session exit. The backgrounded sweep subshell must not hold
# the hook's stdout open — `| cat` below emulates Claude Code's read-to-EOF;
# with a fake claude that sleeps 5 s, a held pipe makes EOF (and the user's
# quit) wait those 5 s.
echo "--- hook exit does not wait for the sweep (stdout EOF) ---"
TEST_FAILURES=0
tmpdir="$(mktemp -d)"
fake_bin="$tmpdir/bin"; mkdir -p "$fake_bin"
cat > "$fake_bin/claude" << 'FAKE_EOF'
#!/usr/bin/env bash
sleep 5
printf '{"result":"[]","total_cost_usd":0.001,"usage":{"cache_read_input_tokens":1},"is_error":false}\n'
FAKE_EOF
chmod +x "$fake_bin/claude"
transcript="$tmpdir/transcript.jsonl"
printf '{"type":"user","timestamp":"%s","message":{"content":"t"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$transcript"
payload="$(printf '{"session_id":"togi-test-block","transcript_path":"%s","reason":"prompt_input_exit"}' "$transcript")"
_start=$(date +%s)
PATH="$fake_bin:$PATH" \
TOGI_ENABLED=1 \
TOGI_HEADLESS=0 \
TOGI_DEBUG=0 \
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
CLAUDE_PROJECT_DIR="$tmpdir" \
  bash "$SCRIPT" <<< "$payload" | cat >/dev/null
_elapsed=$(( $(date +%s) - _start ))
[ "$_elapsed" -lt 3 ] || fail "hook stdout EOF took ${_elapsed}s — the sweep subshell is holding the hook's pipes and blocking session exit"
# Give the detached sweep time to finish before removing its working dir.
sleep 6
rm -rf "$tmpdir"
if [ "$TEST_FAILURES" -eq 0 ]; then
  echo "  PASS"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
