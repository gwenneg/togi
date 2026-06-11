#!/usr/bin/env bash
# Shared logging for togi hook scripts.
# Source this file near the top of each script:
#   source "$(dirname "$0")/lib/logging.sh"
#
# Provides: log <source> <message>
# Requires: TOGI_DEBUG (optional, default 0), CLAUDE_PROJECT_DIR (optional, default .)

if [ "${TOGI_DEBUG:-0}" = "1" ]; then
  _togi_log_file="${CLAUDE_PROJECT_DIR:-.}/.claude/togi.log"
  mkdir -p "$(dirname "$_togi_log_file")" 2>/dev/null || true
  log() {
    local src="$1"; shift
    printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$src" "$*" >> "$_togi_log_file"
  }
else
  log() { :; }
fi
