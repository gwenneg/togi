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

  # Fake claude: record argv and stdin, then output a JSON friction event.
  cat > "$fake_bin/claude" << 'FAKE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TOGI_TEST_ARGV"
cat > "$TOGI_TEST_STDIN"
printf '[{"type":"clarification","slug":"test-friction-event","doc_gap":"CLAUDE.md","captured_by":"test-model","body":"Test body."}]\n'
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
    [ -n "$(find "$tmpdir/.claude/friction" -name '*.json' 2>/dev/null | head -1)" ] && break
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
  friction_file="$(find "$tmpdir/.claude/friction" -name "*.json" 2>/dev/null | head -1)"
  [ -n "$friction_file" ] || fail "friction JSON file not created from sweep output"
  if [ -n "$friction_file" ]; then
    jq -e '.[0].type == "clarification"'       "$friction_file" >/dev/null 2>&1 || fail "wrong type in friction JSON"
    jq -e --arg s "$session_id" '.[0].session == $s' "$friction_file" >/dev/null 2>&1 || fail "session_id not in friction JSON"
    jq -e '.[0].doc_gap == "CLAUDE.md"'        "$friction_file" >/dev/null 2>&1 || fail "doc_gap not in friction JSON"
    jq -e '.[0].body == "Test body."'          "$friction_file" >/dev/null 2>&1 || fail "body not in friction JSON"
    jq -e '.[0].cache'                         "$friction_file" >/dev/null 2>&1 || fail "cache not added to friction JSON"
    jq -e '.[0].date'                          "$friction_file" >/dev/null 2>&1 || fail "date not added to friction JSON"
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

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
