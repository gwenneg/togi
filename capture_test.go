package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func makeHookInput(t *testing.T, sessionID, transcriptPath string) []byte {
	t.Helper()
	data, err := json.Marshal(hookInput{
		SessionID:      sessionID,
		TranscriptPath: transcriptPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestCapture_Disabled(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	t.Setenv("TOGI_ENABLED", "0")
	cfg := Load()

	capture(cfg, makeHookInput(t, "sess1", "/tmp/transcript.jsonl"))

	if _, err := os.Stat(filepath.Join(dir, ".claude", "friction")); !os.IsNotExist(err) {
		t.Error("friction dir should not be created when disabled")
	}
}

func TestCapture_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	t.Setenv("TOGI_ENABLED", "1")
	cfg := Load()

	capture(cfg, []byte("not valid json"))

	if _, err := os.Stat(filepath.Join(dir, ".claude", "friction")); !os.IsNotExist(err) {
		t.Error("friction dir should not be created for invalid JSON input")
	}
}

func TestCapture_CreatesLogFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CLAUDE_PROJECT_DIR", dir)
	t.Setenv("TOGI_ENABLED", "1")
	cfg := Load()

	// Use a non-.jsonl path so capture-worker exits immediately at path validation
	// rather than polling for 60 seconds waiting for a transcript file.
	capture(cfg, makeHookInput(t, "sess1", "/tmp/transcript.txt"))

	logPath := filepath.Join(dir, ".claude", "friction", "capture.log")
	if _, err := os.Stat(logPath); os.IsNotExist(err) {
		t.Error("capture.log should be created by the parent process before spawning capture-worker")
	}
}
