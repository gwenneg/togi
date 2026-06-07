package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
)

// remind is the SessionStart hook entry point. It counts sessions with unprocessed
// friction and prints a reminder if the threshold is reached.
func remind(cfg *Config) {
	if !cfg.Enabled {
		return
	}

	sessions, events, err := countFriction(cfg.FrictionDir())
	if err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "togi: could not read friction dir: %v\n", err)
	}
	if sessions < cfg.SessionThreshold || events == 0 {
		return
	}

	msg := buildReminderMessage(sessions, events)
	json.NewEncoder(os.Stdout).Encode(struct {
		SystemMessage string `json:"systemMessage"`
	}{msg})
}

// countFriction counts session subdirectories and .md friction files in one pass,
// avoiding the recursive WalkDir that the previous two-function approach required.
func countFriction(dir string) (sessions, events int, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, 0, err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		sessions++
		subEntries, err := os.ReadDir(filepath.Join(dir, e.Name()))
		if err != nil {
			fmt.Fprintf(os.Stderr, "togi: could not read session dir %s: %v\n", e.Name(), err)
			continue
		}
		for _, sub := range subEntries {
			if !sub.IsDir() && strings.HasSuffix(sub.Name(), ".md") {
				events++
			}
		}
	}
	return sessions, events, nil
}

// padLine wraps s in box-drawing border characters with two leading spaces.
// %-48.48s left-aligns within exactly 48 characters: pads with spaces if short,
// truncates if long. Combined with the "║  " prefix, the inner width is always 50.
func padLine(s string) string {
	return fmt.Sprintf("║  %-48.48s║", s)
}

// buildReminderMessage picks a random message from a fixed set and wraps it
// in an ASCII box for display in the Claude Code system prompt.
func buildReminderMessage(sessions, events int) string {
	// Each message is formatted explicitly to avoid fmt.Sprintf argument count mismatches.
	type msg struct{ line1, line2 string }
	msgs := []msg{
		{fmt.Sprintf("%d sessions. %d friction events. I counted.", sessions, events), "The docs won't update themselves. (I've tried.)"},
		{fmt.Sprintf("%d sessions, %d stumbles. I'm not proud.", sessions, events), "Update the docs. For both our sakes."},
		{fmt.Sprintf("%d sessions. %d friction events waiting.", sessions, events), "Evidence suggests the docs need updating."},
		{fmt.Sprintf("Good news: %d sessions of insights!", sessions), fmt.Sprintf("Bad news: %d events rotting in .claude/friction/.", events)},
		{fmt.Sprintf("ERROR: %d sessions, %d unprocessed friction events.", sessions, events), "RECOMMENDED ACTION: update the docs. Please."},
	}
	m := msgs[rand.Intn(len(msgs))]

	const border = "══════════════════════════════════════════════════"
	empty := "║" + strings.Repeat(" ", 50) + "║"
	lines := []string{
		"\n╔" + border + "╗",
		"║  TOGI — FRICTION REMINDER                        ║",
		"╠" + border + "╣",
		empty,
		padLine(m.line1),
		padLine(m.line2),
		empty,
		"║  → /togi:update-context-docs                     ║",
		empty,
		"║  Not your thing? Run /togi:disable.              ║",
		"╚" + border + "╝",
	}
	return strings.Join(lines, "\n")
}
