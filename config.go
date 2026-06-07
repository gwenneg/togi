package main

import (
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Config holds all runtime configuration for togi, loaded once at startup from
// environment variables. Functions receive *Config instead of reading env vars directly.
type Config struct {
	// Controlled by the developer via .claude/settings.json or .claude/settings.local.json
	Enabled             bool   // TOGI_ENABLED=1
	MaxTranscriptKB     int    // TOGI_MAX_TRANSCRIPT_KB, default 200
	Model               string // TOGI_CAPTURE_MODEL, default haiku
	SessionThreshold    int    // TOGI_SESSION_THRESHOLD, default 3

	// Injected by Claude Code
	ProjectDir string // CLAUDE_PROJECT_DIR

	// Derived — not exposed as env vars
	ClaudeTimeout time.Duration // timeout for the claude -p subprocess
}

func Load() *Config {
	projectDir := envOrDefault("CLAUDE_PROJECT_DIR", ".")
	if abs, err := filepath.Abs(projectDir); err == nil {
		projectDir = abs
	}

	return &Config{
		Enabled:          os.Getenv("TOGI_ENABLED") == "1",
		MaxTranscriptKB:  envInt("TOGI_MAX_TRANSCRIPT_KB", 200),
		Model:            envOrDefault("TOGI_CAPTURE_MODEL", "haiku"),
		SessionThreshold: envInt("TOGI_SESSION_THRESHOLD", 3),
		ProjectDir:       projectDir,
		ClaudeTimeout:    5 * time.Minute,
	}
}

// FrictionDir returns the directory where friction event files are stored.
func (c *Config) FrictionDir() string {
	return filepath.Join(c.ProjectDir, ".claude", "friction")
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// envInt parses a positive integer from an environment variable.
// Zero, negative, and non-numeric values fall back to def.
func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}
