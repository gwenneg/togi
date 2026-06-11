#!/usr/bin/env bash
# Regression test: session-end.sh must deliver the prompt via stdin, not as a positional arg.
# --allowedTools is variadic; a trailing positional is consumed as a second tool name,
# leaving --resume promptless and producing "No deferred tool marker found".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/session-end.sh"
# Verbatim string from assets/prompts/capture-friction.md — appears in every rendered prompt.
PROMPT_SENTINEL="Review this entire session for friction events"

PASS=0
FAIL=0
# Per-test failure counter (global so fail() can write it without a subshell).
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

  # Fake claude: record argv (one arg per line) and full stdin, then exit 0.
  # Uses TOGI_TEST_ARGV / TOGI_TEST_STDIN env vars so the paths survive nohup.
  cat > "$fake_bin/claude" << 'FAKE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TOGI_TEST_ARGV"
cat > "$TOGI_TEST_STDIN"
FAKE_EOF
  chmod +x "$fake_bin/claude"

  # Sample transcript: ≥3 user entries with a controlled timestamp.
  local ts
  if [ "$ts_age" = "fresh" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"   # now → warm cache
  else
    ts="2020-01-01T00:00:00.000Z"              # ancient → cold cache → haiku
  fi
  local transcript="$tmpdir/transcript.jsonl"
  for i in 1 2 3; do
    printf '{"type":"user","timestamp":"%s"}\n' "$ts" >> "$transcript"
  done

  local session_id="togi-test-abc123"
  local payload; payload="$(printf '{"session_id":"%s","transcript_path":"%s"}' "$session_id" "$transcript")"

  # Run the hook. Export test paths so nohup'd fake claude inherits them.
  TOGI_TEST_ARGV="$argv_file" \
  TOGI_TEST_STDIN="$stdin_file" \
  PATH="$fake_bin:$PATH" \
  TOGI_ENABLED=1 \
  TOGI_HEADLESS=0 \
  TOGI_DEBUG=0 \
  TOGI_MIN_TURNS=3 \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" <<< "$payload"

  # Wait up to 5 s for the nohup'd fake claude to write its output files.
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

  # --- argv assertions ---
  grep -qx -- '-p'             "$argv_file" || fail "-p missing from argv"
  grep -qx -- '--resume'       "$argv_file" || fail "--resume missing from argv"
  grep -qx -- "$session_id"    "$argv_file" || fail "session_id missing from argv"
  grep -qx -- '--fork-session' "$argv_file" || fail "--fork-session missing from argv"
  grep -qx -- '--allowedTools' "$argv_file" || fail "--allowedTools missing from argv"
  grep -qxF 'Write(.claude/friction/**)' "$argv_file" || fail "tool value missing from argv"

  # The prompt must NOT appear in argv (variadic swallow regression).
  grep -qF "$PROMPT_SENTINEL" "$argv_file" && fail "prompt text found in argv — variadic swallow bug" || true

  # --- stdin assertions ---
  grep -qF "$PROMPT_SENTINEL" "$stdin_file" || fail "prompt sentinel missing from stdin"
  grep -qF "$session_id"      "$stdin_file" || fail "session_id not substituted in stdin"

  # --- model selection ---
  if [ "$expect_haiku" = "yes" ]; then
    grep -qx -- '--model' "$argv_file" || fail "--model missing from argv for cold session"
    grep -qx -- 'haiku'   "$argv_file" || fail "haiku missing from argv for cold session"
  else
    ! grep -qx -- '--model' "$argv_file" || fail "unexpected --model in argv for warm session"
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

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
