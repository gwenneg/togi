package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── readJSONFile / writeJSONFile ─────────────────────────────────────────────

func TestReadJSONFile_NotExist(t *testing.T) {
	m, err := readJSONFile(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(m) != 0 {
		t.Errorf("expected empty map, got %v", m)
	}
}

func TestReadJSONFile_InvalidJSON(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.json")
	os.WriteFile(path, []byte("not json"), 0644)

	_, err := readJSONFile(path)
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestWriteReadJSONFile_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")

	original := map[string]json.RawMessage{
		"foo": json.RawMessage(`"bar"`),
		"num": json.RawMessage(`42`),
	}
	if err := writeJSONFile(path, original); err != nil {
		t.Fatalf("write error: %v", err)
	}

	got, err := readJSONFile(path)
	if err != nil {
		t.Fatalf("read error: %v", err)
	}
	if string(got["foo"]) != `"bar"` {
		t.Errorf("foo = %s, want %q", got["foo"], `"bar"`)
	}
	if string(got["num"]) != `42` {
		t.Errorf("num = %s, want 42", got["num"])
	}
}

func TestWriteJSONFile_Atomic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	m := map[string]json.RawMessage{"key": json.RawMessage(`"value"`)}

	if err := writeJSONFile(path, m); err != nil {
		t.Fatal(err)
	}
	// Temp file must be cleaned up after successful write.
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Error("temp file should not exist after successful write")
	}
}

// ─── addHookIfMissing ─────────────────────────────────────────────────────────

func TestAddHookIfMissing_AddsWhenAbsent(t *testing.T) {
	groups := []hookGroup{}
	addHookIfMissing(&groups, ".claude/bin/togi remind", 2000)

	if len(groups) != 1 {
		t.Fatalf("expected 1 group, got %d", len(groups))
	}
	if groups[0].Hooks[0].Command != ".claude/bin/togi remind" {
		t.Errorf("unexpected command: %s", groups[0].Hooks[0].Command)
	}
	if groups[0].Hooks[0].Timeout != 2000 {
		t.Errorf("unexpected timeout: %d", groups[0].Hooks[0].Timeout)
	}
}

func TestAddHookIfMissing_SkipsWhenPresent(t *testing.T) {
	groups := []hookGroup{{
		Matcher: "",
		Hooks:   []hookCmd{{Type: "command", Command: ".claude/bin/togi remind", Timeout: 2000}},
	}}
	addHookIfMissing(&groups, ".claude/bin/togi remind", 2000)

	if len(groups) != 1 {
		t.Errorf("expected 1 group (no duplicate), got %d", len(groups))
	}
}

// ─── configureGitignore ───────────────────────────────────────────────────────

func TestConfigureGitignore_CreatesFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	cfg := Load()

	configureGitignore(cfg)

	content, err := os.ReadFile(filepath.Join(dir, ".gitignore"))
	if err != nil {
		t.Fatalf("could not read .gitignore: %v", err)
	}
	for _, entry := range gitignoreEntries {
		if !strings.Contains(string(content), entry) {
			t.Errorf(".gitignore missing entry: %q", entry)
		}
	}
}

func TestConfigureGitignore_NoopWhenPresent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	cfg := Load()

	// Write all entries upfront.
	path := filepath.Join(dir, ".gitignore")
	os.WriteFile(path, []byte(strings.Join(gitignoreEntries, "\n")+"\n"), 0644)
	before, _ := os.ReadFile(path)

	configureGitignore(cfg)

	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Error("gitignore should not be modified when all entries are already present")
	}
}

func TestConfigureGitignore_AddsTrailingNewline(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	cfg := Load()

	// Write a file without a trailing newline.
	path := filepath.Join(dir, ".gitignore")
	os.WriteFile(path, []byte("# existing"), 0644)

	configureGitignore(cfg)

	content, _ := os.ReadFile(path)
	lines := strings.Split(string(content), "\n")
	// The first line should still be the original comment.
	if lines[0] != "# existing" {
		t.Errorf("first line = %q, want %q", lines[0], "# existing")
	}
}

// ─── setTogiEnabled ───────────────────────────────────────────────────────────

func TestSetTogiEnabled_Enable(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	cfg := Load()

	if err := setTogiEnabled(cfg, "1"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	path := filepath.Join(dir, ".claude", "settings.local.json")
	m, _ := readJSONFile(path)
	var env map[string]string
	json.Unmarshal(m["env"], &env)

	if env["TOGI_ENABLED"] != "1" {
		t.Errorf("TOGI_ENABLED = %q, want %q", env["TOGI_ENABLED"], "1")
	}
}

func TestSetTogiEnabled_PreservesExistingEnv(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	cfg := Load()

	// Pre-populate with an existing env var.
	path := filepath.Join(dir, ".claude", "settings.local.json")
	os.MkdirAll(filepath.Dir(path), 0755)
	writeJSONFile(path, map[string]json.RawMessage{
		"env": json.RawMessage(`{"OTHER_VAR": "preserved"}`),
	})

	setTogiEnabled(cfg, "1")

	m, _ := readJSONFile(path)
	var env map[string]string
	json.Unmarshal(m["env"], &env)

	if env["OTHER_VAR"] != "preserved" {
		t.Errorf("OTHER_VAR = %q, want %q", env["OTHER_VAR"], "preserved")
	}
	if env["TOGI_ENABLED"] != "1" {
		t.Errorf("TOGI_ENABLED = %q, want %q", env["TOGI_ENABLED"], "1")
	}
}
