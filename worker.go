package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const maxDescriptionLen = 2000

// validEventTypes is the set of friction event types the model is instructed to produce.
var validEventTypes = map[string]bool{
	"correction":    true,
	"clarification": true,
	"denial":        true,
	"mistake":       true,
}

// frictionEvent maps to the JSON objects returned by the model in callClaude.
type frictionEvent struct {
	Type        string `json:"type"`
	Slug        string `json:"slug"`
	DocGap      string `json:"doc_gap"`
	Description string `json:"description"`
}

// captureWorker runs in the background after being spawned by capture.
// It parses the session transcript, calls the model, and writes friction files.
func captureWorker(cfg *Config, input []byte) {
	var hi hookInput
	if err := json.Unmarshal(input, &hi); err != nil {
		logf("ERROR: invalid hook input: %v", err)
		return
	}

	shortID := hi.SessionID[:min(4, len(hi.SessionID))]
	if shortID == "" {
		shortID = "unkn"
	}

	lockPath := filepath.Join(cfg.FrictionDir(), ".capture.lock")
	lockFile := acquireLock(lockPath)
	if lockFile == nil {
		return
	}
	defer releaseLock(lockFile, lockPath)

	if hi.TranscriptPath == "" {
		logf("ERROR: session %s: missing transcript_path", shortID)
		return
	}
	// Validate the transcript path before opening it. The path comes from untrusted
	// stdin; without this check, a crafted payload could read arbitrary files and
	// send their contents to the Anthropic API.
	if !filepath.IsAbs(hi.TranscriptPath) || !strings.HasSuffix(hi.TranscriptPath, ".jsonl") {
		logf("ERROR: session %s: transcript_path must be an absolute .jsonl path", shortID)
		return
	}

	logf("INFO: session %s: friction capture started", shortID)

	transcript, err := waitForTranscript(hi.TranscriptPath)
	if err != nil {
		logf("ERROR: session %s: %v", shortID, err)
		return
	}

	if len(transcript) < 200 {
		logf("INFO: session %s: transcript too short (%d chars), skipping", shortID, len(transcript))
		return
	}

	maxBytes := cfg.MaxTranscriptKB * 1024
	if len(transcript) > maxBytes {
		transcript = transcript[len(transcript)-maxBytes:]
		// Slicing at a byte boundary can split a multi-byte UTF-8 rune. Strip any
		// resulting invalid sequences so the API receives valid UTF-8.
		transcript = strings.ToValidUTF8(transcript, "")
	}

	// Prevent prompt injection via the XML-like delimiter used in the prompt.
	transcript = strings.ReplaceAll(transcript, "</transcript>", "</ transcript>")

	result, err := callClaude(cfg, transcript)
	if err != nil {
		logf("ERROR: session %s: %v", shortID, err)
		return
	}

	result = strings.TrimSpace(stripMarkdownFences(result))

	if result == "" || result == "[]" {
		logf("INFO: session %s: no friction found", shortID)
		return
	}

	var events []frictionEvent
	if err := json.Unmarshal([]byte(result), &events); err != nil {
		logf("ERROR: session %s: model returned invalid JSON: %.200s", shortID, result)
		return
	}

	logf("INFO: session %s: found %d friction event(s)", shortID, len(events))

	safeSessionID := sanitizeSessionID(hi.SessionID)
	sessionDir := filepath.Join(cfg.FrictionDir(), safeSessionID)
	if err := os.MkdirAll(sessionDir, 0755); err != nil {
		logf("ERROR: session %s: could not create session dir: %v", shortID, err)
		return
	}

	today := time.Now().Format("2006-01-02")

	for _, event := range events {
		slug := sanitizeSlug(event.Slug)

		if !validEventTypes[event.Type] {
			event.Type = "correction"
		}

		rel, ok := validateDocGap(event.DocGap, cfg.ProjectDir)
		if !ok {
			logf("WARN: session %s: skipping %q — invalid doc_gap %q", shortID, slug, event.DocGap)
			continue
		}

		desc := event.Description
		if len(desc) > maxDescriptionLen {
			desc = desc[:maxDescriptionLen]
		}

		content := fmt.Sprintf("---\ntype: %s\ndoc_gap: %s\ndate: %s\n---\n\n%s\n",
			event.Type, rel, today, desc)

		filename := filepath.Join(sessionDir, slug+".md")
		if err := os.WriteFile(filename, []byte(content), 0644); err != nil {
			logf("ERROR: session %s: could not write %s: %v", shortID, filename, err)
			continue
		}
		logf("INFO: -> %s/%s.md (%s)", safeSessionID, slug, event.Type)
	}

	logf("INFO: session %s: friction capture complete", shortID)
}

// waitForTranscript polls the transcript file until it contains at least one
// user or assistant turn. Claude Code may still be writing the file when the
// SessionEnd hook fires, so polling is necessary.
func waitForTranscript(path string) (string, error) {
	const pollMax = 60 * time.Second
	buf := make([]byte, 1024*1024) // allocated once, reused across poll iterations
	deadline := time.Now().Add(pollMax)
	for time.Now().Before(deadline) {
		transcript, err := parseTranscript(path, buf)
		if err != nil {
			return "", fmt.Errorf("failed to parse transcript at %s: %w", path, err)
		}
		if transcript != "" {
			return transcript, nil
		}
		time.Sleep(time.Second)
	}
	return "", fmt.Errorf("no user/assistant turns found after %s", pollMax)
}

// parseTranscript reads a Claude Code JSONL transcript and returns the
// conversational text as "[user]: ..." / "[assistant]: ..." lines.
// Tool result blocks are excluded — only text typed in conversation is included.
func parseTranscript(path string, buf []byte) (string, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return "", nil // not written yet, keep polling
	}
	if err != nil {
		return "", err
	}
	defer f.Close()

	var sb strings.Builder
	scanner := bufio.NewScanner(f)
	scanner.Buffer(buf, len(buf))

	for scanner.Scan() {
		var line struct {
			Type    string `json:"type"`
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &line); err != nil {
			continue
		}
		if line.Type != "user" && line.Type != "assistant" {
			continue
		}
		text := extractText(line.Message.Content)
		if text == "" {
			continue
		}
		fmt.Fprintf(&sb, "[%s]: %s\n", line.Type, text)
	}

	return sb.String(), scanner.Err()
}

// extractText pulls plain text from a message content field, which can be either
// a bare string or an array of typed content blocks. Tool result blocks are excluded.
func extractText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		var parts []string
		for _, b := range blocks {
			if b.Type == "text" && b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		return strings.Join(parts, " ")
	}
	return ""
}

// callClaude runs the friction analysis prompt through the configured model
// using the claude CLI in non-interactive mode.
func callClaude(cfg *Config, transcript string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), cfg.ClaudeTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "claude", "-p", "--model", cfg.Model)
	cmd.Stdin = strings.NewReader(buildPrompt(transcript))

	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return "", fmt.Errorf("claude timed out after %s", cfg.ClaudeTimeout)
		}
		return "", fmt.Errorf("claude exited with error: %w", err)
	}
	return string(out), nil
}

// buildPrompt constructs the friction analysis prompt sent to the model.
func buildPrompt(transcript string) string {
	return `Analyze this coding agent session for friction signals worth capturing as documentation gaps.

Friction = a moment where the human corrected the agent, the agent asked a question it
shouldn't have needed to ask, the agent made a wrong assumption, or a tool call was denied.

Before including an event, apply both filters:
1. Would adding a concrete rule, example, or convention to a specific project doc have
   prevented this in a future session?
2. Would the same misunderstanding likely recur on a similar task — not just this specific case?
If either answer is no, exclude the event.

Exclude the following — they are noise:
- User errors: the user made a mistake in their own request and corrected it themselves
- Tool denials that are one-off decisions — but DO capture denials that reveal a standing
  project policy (e.g. "we never run migrations directly")
- Mid-session scope changes or preference pivots by the user
- Transient or environmental errors (network issues, flaky tests, API timeouts)
- Corrections to generated code that are case-specific and would not recur on similar tasks
- Requirement clarifications that depend on context no project doc could have anticipated

For each qualifying event, output a JSON array. Each element must have:
- type: one of correction, clarification, denial, mistake
- slug: short-kebab-case-description using only lowercase letters, digits, and hyphens
- doc_gap: relative path from the project root to the target file (e.g. docs/api-guidelines.md).
  Must be a specific plausible file path. No absolute paths. No paths starting with ".".
  If you cannot name a specific target file, exclude the event entirely.
- description: one paragraph — what the agent did wrong, what project-specific knowledge was
  missing, and the concrete rule or example that would prevent it from recurring.

If no qualifying friction was found, output an empty array: []

<transcript>
` + transcript + `
</transcript>

Output ONLY valid JSON. Do not use markdown formatting, code fences, or any other text.`
}

func stripMarkdownFences(s string) string {
	lines := strings.Split(s, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		if !strings.HasPrefix(line, "```") {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// logf writes a timestamped log line to stdout. When captureWorker runs as a
// background subprocess, its stdout is redirected to capture.log by the parent.
func logf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stdout, time.Now().Format("15:04:05")+" "+format+"\n", args...)
}
