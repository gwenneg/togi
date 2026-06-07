package main

import (
	"path/filepath"
	"testing"
)

func TestEnvOrDefault(t *testing.T) {
	tests := []struct {
		name     string
		key      string
		value    string // empty = unset
		def      string
		expected string
	}{
		{"set", "TEST_KEY", "myvalue", "default", "myvalue"},
		{"unset", "TEST_KEY", "", "default", "default"},
		{"empty string falls back to default", "TEST_KEY_EMPTY", " ", "default", " "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.value != "" {
				t.Setenv(tt.key, tt.value)
			}
			got := envOrDefault(tt.key, tt.def)
			if got != tt.expected {
				t.Errorf("envOrDefault(%q) = %q, want %q", tt.key, got, tt.expected)
			}
		})
	}
}

func TestEnvInt(t *testing.T) {
	tests := []struct {
		name     string
		value    string // empty = unset
		def      int
		expected int
	}{
		{"valid positive", "5", 3, 5},
		{"unset uses default", "", 3, 3},
		{"zero falls back to default", "0", 3, 3},
		{"negative falls back to default", "-1", 3, 3},
		{"non-numeric falls back to default", "abc", 3, 3},
		{"float falls back to default", "1.5", 3, 3},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			const key = "TEST_ENV_INT"
			if tt.value != "" {
				t.Setenv(key, tt.value)
			}
			got := envInt(key, tt.def)
			if got != tt.expected {
				t.Errorf("envInt(%q) = %d, want %d", tt.value, got, tt.expected)
			}
		})
	}
}

func TestLoad_Defaults(t *testing.T) {
	t.Setenv("TOGI_ENABLED", "")
	t.Setenv("TOGI_CAPTURE_MODEL", "")
	t.Setenv("TOGI_SESSION_THRESHOLD", "")
	t.Setenv("TOGI_MAX_TRANSCRIPT_KB", "")
	t.Setenv("CLAUDE_PROJECT_DIR", "/tmp/testproject")

	cfg := Load()

	if cfg.Enabled {
		t.Error("Enabled should be false by default")
	}
	if cfg.Model != "haiku" {
		t.Errorf("Model = %q, want %q", cfg.Model, "haiku")
	}
	if cfg.SessionThreshold != 3 {
		t.Errorf("SessionThreshold = %d, want 3", cfg.SessionThreshold)
	}
	if cfg.MaxTranscriptKB != 200 {
		t.Errorf("MaxTranscriptKB = %d, want 200", cfg.MaxTranscriptKB)
	}
}

func TestLoad_EnvVars(t *testing.T) {
	t.Setenv("TOGI_ENABLED", "1")
	t.Setenv("TOGI_CAPTURE_MODEL", "sonnet")
	t.Setenv("TOGI_SESSION_THRESHOLD", "5")
	t.Setenv("TOGI_MAX_TRANSCRIPT_KB", "100")
	t.Setenv("CLAUDE_PROJECT_DIR", "/tmp/testproject")

	cfg := Load()

	if !cfg.Enabled {
		t.Error("Enabled should be true when TOGI_ENABLED=1")
	}
	if cfg.Model != "sonnet" {
		t.Errorf("Model = %q, want %q", cfg.Model, "sonnet")
	}
	if cfg.SessionThreshold != 5 {
		t.Errorf("SessionThreshold = %d, want 5", cfg.SessionThreshold)
	}
	if cfg.MaxTranscriptKB != 100 {
		t.Errorf("MaxTranscriptKB = %d, want 100", cfg.MaxTranscriptKB)
	}
}

func TestLoad_ProjectDir(t *testing.T) {
	t.Setenv("CLAUDE_PROJECT_DIR", "/tmp/testproject")
	cfg := Load()

	if cfg.ProjectDir != "/tmp/testproject" {
		t.Errorf("ProjectDir = %q, want %q", cfg.ProjectDir, "/tmp/testproject")
	}
}

func TestLoad_ProjectDirDefault(t *testing.T) {
	t.Setenv("CLAUDE_PROJECT_DIR", "")
	cfg := Load()

	// Default "." is resolved to an absolute path by filepath.Abs.
	if !filepath.IsAbs(cfg.ProjectDir) {
		t.Errorf("ProjectDir %q should be absolute when defaulting to current directory", cfg.ProjectDir)
	}
}

func TestFrictionDir(t *testing.T) {
	t.Setenv("CLAUDE_PROJECT_DIR", "/tmp/testproject")
	cfg := Load()

	want := "/tmp/testproject/.claude/friction"
	if got := cfg.FrictionDir(); got != want {
		t.Errorf("FrictionDir() = %q, want %q", got, want)
	}
}
