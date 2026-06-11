#!/usr/bin/env bash
# Shared logging for togi hook scripts.
# Source this file near the top of each script:
#   source "$(dirname "$0")/lib/logging.sh"
#
# Provides: LOG (path), log <source> <message>
# Requires: TOGI_DEBUG (optional, default 0), CLAUDE_PROJECT_DIR (optional, default .)

if [ "${TOGI_DEBUG:-0}" = "1" ]; then
  LOG="${CLAUDE_PROJECT_DIR:-.}/.claude/togi.log"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  log() {
    local src="$1"; shift
    printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$src" "$*" >> "$LOG"
  }
else
  LOG=/dev/null
  log() { :; }
fi
