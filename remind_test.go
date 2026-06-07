package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── countFriction ────────────────────────────────────────────────────────────

func TestCountFriction_Empty(t *testing.T) {
	dir := t.TempDir()
	sessions, events, err := countFriction(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sessions != 0 || events != 0 {
		t.Errorf("got %d sessions, %d events; want 0, 0", sessions, events)
	}
}

func TestCountFriction_NotExist(t *testing.T) {
	_, _, err := countFriction("/nonexistent/togi-test-path")
	if err == nil {
		t.Error("expected error for non-existent dir")
	}
	if !os.IsNotExist(err) {
		t.Errorf("expected IsNotExist error, got: %v", err)
	}
}

func TestCountFriction_Counts(t *testing.T) {
	dir := t.TempDir()
	sess1 := filepath.Join(dir, "session-1")
	sess2 := filepath.Join(dir, "session-2")
	os.Mkdir(sess1, 0755)
	os.Mkdir(sess2, 0755)

	// Three .md friction files across two sessions.
	os.WriteFile(filepath.Join(sess1, "event-a.md"), []byte("test"), 0644)
	os.WriteFile(filepath.Join(sess1, "event-b.md"), []byte("test"), 0644)
	os.WriteFile(filepath.Join(sess2, "event-c.md"), []byte("test"), 0644)

	// Non-.md file should not be counted.
	os.WriteFile(filepath.Join(sess1, "ignored.txt"), []byte("test"), 0644)

	sessions, events, err := countFriction(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sessions != 2 {
		t.Errorf("sessions = %d, want 2", sessions)
	}
	if events != 3 {
		t.Errorf("events = %d, want 3", events)
	}
}

func TestCountFriction_TopLevelFilesIgnored(t *testing.T) {
	dir := t.TempDir()
	// Files at the top level (e.g. capture.log) should not be counted as sessions.
	os.WriteFile(filepath.Join(dir, "capture.log"), []byte("test"), 0644)

	sessions, events, err := countFriction(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sessions != 0 || events != 0 {
		t.Errorf("got %d sessions, %d events; want 0, 0", sessions, events)
	}
}

// ─── padLine ─────────────────────────────────────────────────────────────────

func TestPadLine_ShortString(t *testing.T) {
	result := padLine("hi")
	// ║ (1 rune) + "  hi" + 46 spaces + ║ (1 rune) = 52 runes
	if runes := []rune(result); len(runes) != 52 {
		t.Errorf("len = %d runes, want 52", len(runes))
	}
	if !strings.HasPrefix(result, "║  hi") {
		t.Errorf("unexpected prefix in %q", result)
	}
	if !strings.HasSuffix(result, "║") {
		t.Errorf("missing closing border in %q", result)
	}
}

func TestPadLine_LongStringTruncated(t *testing.T) {
	long := strings.Repeat("x", 60)
	result := padLine(long)
	if runes := []rune(result); len(runes) != 52 {
		t.Errorf("len = %d runes, want 52 (long string should be truncated)", len(runes))
	}
}

func TestPadLine_ExactlyMaxLength(t *testing.T) {
	exact := strings.Repeat("x", 48)
	result := padLine(exact)
	if runes := []rune(result); len(runes) != 52 {
		t.Errorf("len = %d runes, want 52", len(runes))
	}
}

// ─── buildReminderMessage ─────────────────────────────────────────────────────

func TestBuildReminderMessage_ContainsExpectedContent(t *testing.T) {
	msg := buildReminderMessage(5, 12)

	checks := []string{
		"TOGI",
		"/togi:update-context-docs",
		"/togi:disable",
		"╔", "╗", "╚", "╝", "║",
	}
	for _, s := range checks {
		if !strings.Contains(msg, s) {
			t.Errorf("message does not contain %q", s)
		}
	}
}

func TestBuildReminderMessage_ContainsCounts(t *testing.T) {
	msg := buildReminderMessage(7, 3)
	if !strings.Contains(msg, "7") {
		t.Error("message does not contain session count (7)")
	}
	if !strings.Contains(msg, "3") {
		t.Error("message does not contain event count (3)")
	}
}
