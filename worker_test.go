package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── extractText ─────────────────────────────────────────────────────────────

func TestExtractText_StringContent(t *testing.T) {
	raw := json.RawMessage(`"hello world"`)
	got := extractText(raw)
	if got != "hello world" {
		t.Errorf("got %q, want %q", got, "hello world")
	}
}

func TestExtractText_ArrayOfBlocks(t *testing.T) {
	raw := json.RawMessage(`[{"type":"text","text":"hello"},{"type":"text","text":"world"}]`)
	got := extractText(raw)
	if got != "hello world" {
		t.Errorf("got %q, want %q", got, "hello world")
	}
}

func TestExtractText_ToolResultExcluded(t *testing.T) {
	// tool_result blocks must not be included — they can contain file contents.
	raw := json.RawMessage(`[{"type":"text","text":"user said this"},{"type":"tool_result","content":"file contents"}]`)
	got := extractText(raw)
	if got != "user said this" {
		t.Errorf("got %q, want %q", got, "user said this")
	}
}

func TestExtractText_Empty(t *testing.T) {
	if got := extractText(json.RawMessage{}); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

// ─── stripMarkdownFences ─────────────────────────────────────────────────────

func TestStripMarkdownFences_NoFences(t *testing.T) {
	input := `{"key": "value"}`
	got := stripMarkdownFences(input)
	if got != input {
		t.Errorf("got %q, want %q", got, input)
	}
}

func TestStripMarkdownFences_WithFences(t *testing.T) {
	input := "```\n[{\"key\":\"value\"}]\n```"
	got := stripMarkdownFences(input)
	if strings.Contains(got, "```") {
		t.Errorf("fences not stripped: %q", got)
	}
	if !strings.Contains(got, `"key"`) {
		t.Errorf("content missing after stripping: %q", got)
	}
}

func TestStripMarkdownFences_WithLanguageTag(t *testing.T) {
	input := "```json\n[]\n```"
	got := stripMarkdownFences(input)
	if strings.Contains(got, "```") {
		t.Errorf("language-tagged fence not stripped: %q", got)
	}
}

// ─── buildPrompt ─────────────────────────────────────────────────────────────

func TestBuildPrompt_ContainsTranscript(t *testing.T) {
	transcript := "unique-transcript-marker-12345"
	prompt := buildPrompt(transcript)

	if !strings.Contains(prompt, transcript) {
		t.Error("prompt does not contain the transcript")
	}
	if !strings.Contains(prompt, "<transcript>") {
		t.Error("prompt missing <transcript> tag")
	}
	if !strings.Contains(prompt, "</transcript>") {
		t.Error("prompt missing </transcript> tag")
	}
}

func TestBuildPrompt_ContainsInstructions(t *testing.T) {
	prompt := buildPrompt("test")
	checks := []string{
		"correction",
		"clarification",
		"denial",
		"mistake",
		"doc_gap",
		"Output ONLY valid JSON",
	}
	for _, s := range checks {
		if !strings.Contains(prompt, s) {
			t.Errorf("prompt missing expected instruction: %q", s)
		}
	}
}

// ─── parseTranscript ─────────────────────────────────────────────────────────

func TestParseTranscript_NotExist(t *testing.T) {
	buf := make([]byte, 1024)
	result, err := parseTranscript("/nonexistent/path.jsonl", buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != "" {
		t.Errorf("expected empty result for missing file, got %q", result)
	}
}

func TestParseTranscript_ValidTurns(t *testing.T) {
	lines := []string{
		`{"type":"user","message":{"content":"hello from user"}}`,
		`{"type":"assistant","message":{"content":"hello from assistant"}}`,
		`{"type":"system","message":{"content":"should be ignored"}}`,
	}
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)

	buf := make([]byte, 1024*1024)
	result, err := parseTranscript(path, buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result, "[user]: hello from user") {
		t.Errorf("missing user turn in: %q", result)
	}
	if !strings.Contains(result, "[assistant]: hello from assistant") {
		t.Errorf("missing assistant turn in: %q", result)
	}
	if strings.Contains(result, "should be ignored") {
		t.Errorf("system message should not be included: %q", result)
	}
}

func TestParseTranscript_ArrayContent(t *testing.T) {
	line := `{"type":"user","message":{"content":[{"type":"text","text":"array content"}]}}`
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	os.WriteFile(path, []byte(line), 0644)

	buf := make([]byte, 1024*1024)
	result, err := parseTranscript(path, buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result, "array content") {
		t.Errorf("array content not parsed: %q", result)
	}
}

func TestParseTranscript_MalformedLinesSkipped(t *testing.T) {
	lines := []string{
		`not valid json`,
		`{"type":"user","message":{"content":"valid"}}`,
	}
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)

	buf := make([]byte, 1024*1024)
	result, err := parseTranscript(path, buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(result, "valid") {
		t.Errorf("valid line not included: %q", result)
	}
}
