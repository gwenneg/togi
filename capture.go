package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

type hookInput struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
}

// capture is the SessionEnd hook entry point. It reads the hook payload from stdin,
// then spawns capture-worker in the background so the hook returns immediately.
func capture(cfg *Config, input []byte) {
	if !cfg.Enabled {
		return
	}

	var hi hookInput
	if err := json.Unmarshal(input, &hi); err != nil {
		return
	}

	frictionDir := cfg.FrictionDir()
	if err := os.MkdirAll(frictionDir, 0755); err != nil {
		return
	}

	logPath := filepath.Join(frictionDir, "capture.log")
	logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer logFile.Close()

	// Re-invoke the running binary as capture-worker rather than hardcoding a path,
	// so the right binary is used regardless of where it is installed.
	exe, err := os.Executable()
	if err != nil {
		return
	}

	// Spawn capture-worker with the hook payload piped to its stdin.
	// Setting Stdout/Stderr to a regular file (not a pipe) ensures Claude Code's
	// stdout/stderr pipes are not inherited by the child, so Claude Code sees EOF
	// and continues as soon as this process exits.
	cmd := exec.Command(exe, "capture-worker")
	cmd.Stdin = bytes.NewReader(input)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(logFile, "ERROR: could not start capture-worker: %v\n", err)
	}
	// Intentionally not calling Wait — capture-worker runs in the background.
}
