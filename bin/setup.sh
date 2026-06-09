#!/bin/bash
# Idempotent project setup for togi.
# Configures marketplace, plugin, CLAUDE.md import, and .gitignore.
# Safe to run multiple times — existing content is never overwritten.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
CLAUDE_DIR="$PROJECT_DIR/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "─── togi configure ─────────────────────────────────"

# ─── settings.json ────────────────────────────────────────────────────────────

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Atomic write helper: pass all args to jq, write to .tmp then rename.
# Usage: jq_edit [--arg key val ...] 'filter'
jq_edit() {
  jq "$@" "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
}

# Add togi marketplace entry if missing.
if jq -e '.extraKnownMarketplaces.togi' "$SETTINGS" > /dev/null 2>&1; then
  echo "Already present   : togi marketplace"
else
  jq_edit '
    .extraKnownMarketplaces.togi = {
      "source": {"source": "github", "repo": "gwenneg/togi"},
      "autoUpdate": true
    }
  '
  echo "Added             : togi marketplace (auto-update enabled)"
fi

# Add togi@togi to enabledPlugins if missing.
PLUGIN_ENTRY="togi@togi"
if jq -e --arg p "$PLUGIN_ENTRY" '.enabledPlugins[$p] == true' "$SETTINGS" > /dev/null 2>&1; then
  echo "Already present   : enabledPlugins[togi@togi]"
else
  jq_edit --arg p "$PLUGIN_ENTRY" '.enabledPlugins[$p] = true'
  echo "Added             : enabledPlugins[togi@togi]"
fi

echo "Updated           : .claude/settings.json"

# ─── capture-friction.md ──────────────────────────────────────────────────

if cmp -s "${CLAUDE_PLUGIN_ROOT}/assets/capture-friction.md" "$CLAUDE_DIR/capture-friction.md" 2>/dev/null; then
  echo "Already present   : .claude/capture-friction.md"
else
  cp "${CLAUDE_PLUGIN_ROOT}/assets/capture-friction.md" "$CLAUDE_DIR/capture-friction.md"
  echo "Updated           : .claude/capture-friction.md"
fi

# ─── CLAUDE.md ────────────────────────────────────────────────────────────────

CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
IMPORT_LINE="@.claude/capture-friction.md"
COMMENT="<!-- togi: do not remove the line below — it enables automatic friction capture for this project -->"

if grep -qxF "$IMPORT_LINE" "$CLAUDE_MD" 2>/dev/null; then
  echo "Already present   : CLAUDE.md import"
else
  printf '\n%s\n%s\n' "$COMMENT" "$IMPORT_LINE" >> "$CLAUDE_MD"
  echo "Updated           : CLAUDE.md (added capture-friction.md import)"
fi

# ─── .gitignore ───────────────────────────────────────────────────────────────

GITIGNORE="$PROJECT_DIR/.gitignore"
ENTRIES=(
  "/.claude/*"
  "!/.claude/settings.json"
  "!/.claude/capture-friction.md"
)

# Ensure any existing content ends with a newline before we append.
if [ -s "$GITIGNORE" ] && [ "$(tail -c 1 "$GITIGNORE" | wc -l)" -eq 0 ]; then
  printf '\n' >> "$GITIGNORE"
fi

ADDED=0
for ENTRY in "${ENTRIES[@]}"; do
  if ! grep -qxF "$ENTRY" "$GITIGNORE" 2>/dev/null; then
    printf '%s\n' "$ENTRY" >> "$GITIGNORE"
    ADDED=$((ADDED + 1))
  fi
done

if [ "$ADDED" -gt 0 ]; then
  echo "Updated           : .gitignore (+${ADDED} entries)"
else
  echo "Already present   : .gitignore entries"
fi

echo "────────────────────────────────────────────────────"
echo "Done."
