package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── stripV ───────────────────────────────────────────────────────────────────

func TestStripV(t *testing.T) {
	tests := []struct{ input, want string }{
		{"v1.2.3", "1.2.3"},
		{"1.2.3", "1.2.3"},
		{"v", ""},
		{"", ""},
	}
	for _, tt := range tests {
		if got := stripV(tt.input); got != tt.want {
			t.Errorf("stripV(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

// ─── validTag ─────────────────────────────────────────────────────────────────

func TestValidTag(t *testing.T) {
	valid := []string{"v1.0.0", "v0.1.2", "v1.2.3-alpha", "v10.20.30"}
	for _, tag := range valid {
		if !validTag(tag) {
			t.Errorf("validTag(%q) = false, want true", tag)
		}
	}

	invalid := []string{
		"",
		"V1.0.0",          // uppercase
		"v1.0.0/malicious", // slash
		"v1.0.0\ninjected", // newline
		strings.Repeat("v", 33), // too long
	}
	for _, tag := range invalid {
		if validTag(tag) {
			t.Errorf("validTag(%q) = true, want false", tag)
		}
	}
}

// ─── isListItem ───────────────────────────────────────────────────────────────

func TestIsListItem(t *testing.T) {
	listItems := []string{
		"- item",
		"* item",
		"+ item",
		"1. item",
		"42. item",
	}
	for _, s := range listItems {
		if !isListItem(s) {
			t.Errorf("isListItem(%q) = false, want true", s)
		}
	}

	notListItems := []string{
		"",
		"plain text",
		"no dot after number 1",
		"-no space",
		"1.no space",
	}
	for _, s := range notListItems {
		if isListItem(s) {
			t.Errorf("isListItem(%q) = true, want false", s)
		}
	}
}

// ─── formatChangelog ──────────────────────────────────────────────────────────

func TestFormatChangelog_UnderLimit(t *testing.T) {
	body := "- fix one\n- fix two\n- fix three"
	result := formatChangelog(body, "v1.0.0")

	if !strings.Contains(result, "- fix one") {
		t.Error("expected changelog to contain first item")
	}
	if strings.Contains(result, "…") {
		t.Error("expected no truncation indicator for short changelog")
	}
	if !strings.Contains(result, "https://github.com/gwenneg/togi/releases/tag/v1.0.0") {
		t.Error("expected link to release")
	}
}

func TestFormatChangelog_OverLimit(t *testing.T) {
	var lines []string
	for i := range 15 {
		lines = append(lines, fmt.Sprintf("- fix %d", i))
	}
	result := formatChangelog(strings.Join(lines, "\n"), "v1.0.0")

	if !strings.Contains(result, "…") {
		t.Error("expected truncation indicator for long changelog")
	}
	if !strings.Contains(result, "https://github.com/gwenneg/togi/releases/tag/v1.0.0") {
		t.Error("expected link to release")
	}
}

func TestFormatChangelog_NumberedList(t *testing.T) {
	body := strings.Repeat("1. item\n", 12)
	result := formatChangelog(body, "v1.0.0")
	if !strings.Contains(result, "…") {
		t.Error("expected numbered list items to be counted and truncated")
	}
}

// ─── sha256File ───────────────────────────────────────────────────────────────

func TestSha256File(t *testing.T) {
	content := []byte("hello togi")
	f, err := os.CreateTemp(t.TempDir(), "*.bin")
	if err != nil {
		t.Fatal(err)
	}
	f.Write(content)
	f.Close()

	h := sha256.Sum256(content)
	want := hex.EncodeToString(h[:])

	got, err := sha256File(f.Name())
	if err != nil {
		t.Fatalf("sha256File error: %v", err)
	}
	if got != want {
		t.Errorf("sha256File = %q, want %q", got, want)
	}
}

// ─── extractChecksum ──────────────────────────────────────────────────────────

func TestExtractChecksum_Found(t *testing.T) {
	validSum := strings.Repeat("a", 64)
	content := fmt.Sprintf("%s  togi-linux-amd64\n%s  togi-darwin-arm64\n", validSum, strings.Repeat("b", 64))
	path := filepath.Join(t.TempDir(), "sha256sums.txt")
	os.WriteFile(path, []byte(content), 0644)

	got, err := extractChecksum(path, "togi-linux-amd64")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != validSum {
		t.Errorf("got %q, want %q", got, validSum)
	}
}

func TestExtractChecksum_NotFound(t *testing.T) {
	content := strings.Repeat("a", 64) + "  togi-linux-amd64\n"
	path := filepath.Join(t.TempDir(), "sha256sums.txt")
	os.WriteFile(path, []byte(content), 0644)

	_, err := extractChecksum(path, "togi-darwin-arm64")
	if err == nil {
		t.Error("expected error for missing binary name")
	}
}

func TestExtractChecksum_InvalidHex(t *testing.T) {
	content := strings.Repeat("z", 64) + "  togi-linux-amd64\n" // 'z' is not valid hex
	path := filepath.Join(t.TempDir(), "sha256sums.txt")
	os.WriteFile(path, []byte(content), 0644)

	_, err := extractChecksum(path, "togi-linux-amd64")
	if err == nil {
		t.Error("expected error for invalid hex checksum")
	}
}

func TestExtractChecksum_WrongLength(t *testing.T) {
	content := "abc123  togi-linux-amd64\n" // too short
	path := filepath.Join(t.TempDir(), "sha256sums.txt")
	os.WriteFile(path, []byte(content), 0644)

	_, err := extractChecksum(path, "togi-linux-amd64")
	if err == nil {
		t.Error("expected error for wrong checksum length")
	}
}

// ─── copyFile ─────────────────────────────────────────────────────────────────

func TestCopyFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.bin")
	dst := filepath.Join(dir, "dst.bin")

	content := []byte("copy me")
	os.WriteFile(src, content, 0644)

	if err := copyFile(src, dst); err != nil {
		t.Fatalf("copyFile error: %v", err)
	}

	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("could not read dst: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("dst content = %q, want %q", got, content)
	}
}

func TestCopyFile_RemovesPartialOnError(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "dst.bin")

	// Non-existent source should fail and not leave dst behind.
	err := copyFile(filepath.Join(dir, "nonexistent"), dst)
	if err == nil {
		t.Error("expected error for missing source")
	}
	if _, statErr := os.Stat(dst); !os.IsNotExist(statErr) {
		t.Error("partial destination file should not exist after failed copy")
	}
}
