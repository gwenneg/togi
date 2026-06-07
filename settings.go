package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// enable sets TOGI_ENABLED=1 in .claude/settings.local.json.
func enable(cfg *Config) {
	if err := setTogiEnabled(cfg, "1"); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Friction capture enabled.")
	fmt.Println("At the end of each session, up to 200 KB of the conversation will be sent")
	fmt.Println("to the Anthropic API. Run /togi:disable at any time to opt out.")
}

// disable sets TOGI_ENABLED=0 in .claude/settings.local.json.
func disable(cfg *Config) {
	if err := setTogiEnabled(cfg, "0"); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Friction capture disabled for this repo.")
	fmt.Println("To re-enable, run /togi:enable.")
}

// setTogiEnabled writes TOGI_ENABLED to .claude/settings.local.json, which is
// personal to the developer and not committed to the repo.
func setTogiEnabled(cfg *Config, value string) error {
	path := filepath.Join(cfg.ProjectDir, ".claude", "settings.local.json")
	m, err := readJSONFile(path)
	if err != nil {
		return err
	}

	var env map[string]string
	if raw, ok := m["env"]; ok {
		if err := json.Unmarshal(raw, &env); err != nil {
			return fmt.Errorf("could not parse existing env block in %s: %w", path, err)
		}
	}
	if env == nil {
		env = make(map[string]string)
	}
	env["TOGI_ENABLED"] = value

	raw, _ := json.Marshal(env)
	m["env"] = raw

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return writeJSONFile(path, m)
}

// configure adds the togi hooks, marketplace, and plugin to .claude/settings.json
// and updates .gitignore with the togi allowlist. Existing content is preserved.
func configure(cfg *Config) {
	fmt.Println("─── togi configure ─────────────────────────────────")
	configureSettings(cfg)
	configureGitignore(cfg)
	fmt.Println("────────────────────────────────────────────────────")
	fmt.Println("Done.")
}

// ─── types ────────────────────────────────────────────────────────────────────

type hookCmd struct {
	Type    string `json:"type"`
	Command string `json:"command"`
	Timeout int    `json:"timeout"`
}

type hookGroup struct {
	Matcher string    `json:"matcher"`
	Hooks   []hookCmd `json:"hooks"`
}

type hooksBlock struct {
	SessionStart []hookGroup `json:"SessionStart,omitempty"`
	SessionEnd   []hookGroup `json:"SessionEnd,omitempty"`
}

type marketplaceSource struct {
	Source string `json:"source"`
	Repo   string `json:"repo"`
}

type marketplaceEntry struct {
	Source     marketplaceSource `json:"source"`
	AutoUpdate bool              `json:"autoUpdate"`
}

// ─── settings.json ────────────────────────────────────────────────────────────

// configureSettings merges togi's hooks, marketplace entry, and plugin into
// .claude/settings.json without overwriting existing content.
func configureSettings(cfg *Config) {
	path := filepath.Join(cfg.ProjectDir, ".claude", "settings.json")
	m, err := readJSONFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	configureHooks(m)
	configureMarketplace(m)
	configureEnabledPlugins(m)

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	if err := writeJSONFile(path, m); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Updated           : .claude/settings.json\n")
}

func configureHooks(m map[string]json.RawMessage) {
	var hooks hooksBlock
	if raw, ok := m["hooks"]; ok {
		if err := json.Unmarshal(raw, &hooks); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: could not parse existing hooks — skipping hook configuration: %v\n", err)
			return
		}
	}

	addHookIfMissing(&hooks.SessionStart, ".claude/bin/togi remind", 2000)
	addHookIfMissing(&hooks.SessionEnd, ".claude/bin/togi capture", 5000)

	raw, _ := json.Marshal(hooks)
	m["hooks"] = raw
}

func addHookIfMissing(groups *[]hookGroup, command string, timeout int) {
	for _, g := range *groups {
		for _, h := range g.Hooks {
			if h.Command == command {
				fmt.Printf("Already present   : hook (%s)\n", command)
				return
			}
		}
	}
	*groups = append(*groups, hookGroup{
		Matcher: "",
		Hooks:   []hookCmd{{Type: "command", Command: command, Timeout: timeout}},
	})
	fmt.Printf("Added             : hook (%s)\n", command)
}

func configureMarketplace(m map[string]json.RawMessage) {
	var marketplaces map[string]marketplaceEntry
	if raw, ok := m["extraKnownMarketplaces"]; ok {
		if err := json.Unmarshal(raw, &marketplaces); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: could not parse existing marketplaces — skipping marketplace configuration: %v\n", err)
			return
		}
	}
	if marketplaces == nil {
		marketplaces = make(map[string]marketplaceEntry)
	}

	if _, exists := marketplaces["togi"]; !exists {
		marketplaces["togi"] = marketplaceEntry{
			Source:     marketplaceSource{Source: "github", Repo: "gwenneg/togi"},
			AutoUpdate: true,
		}
		fmt.Println("Added             : togi marketplace (auto-update enabled)")
	} else {
		fmt.Println("Already present   : togi marketplace")
	}

	raw, _ := json.Marshal(marketplaces)
	m["extraKnownMarketplaces"] = raw
}

func configureEnabledPlugins(m map[string]json.RawMessage) {
	var plugins []string
	if raw, ok := m["enabledPlugins"]; ok {
		if err := json.Unmarshal(raw, &plugins); err != nil {
			fmt.Fprintf(os.Stderr, "WARN: could not parse existing enabledPlugins — skipping plugin configuration: %v\n", err)
			return
		}
	}

	const entry = "togi@togi"
	for _, p := range plugins {
		if p == entry {
			fmt.Println("Already present   : enabledPlugins[togi@togi]")
			return
		}
	}
	plugins = append(plugins, entry)
	fmt.Println("Added             : enabledPlugins[togi@togi]")

	raw, _ := json.Marshal(plugins)
	m["enabledPlugins"] = raw
}

// ─── .gitignore ───────────────────────────────────────────────────────────────

var gitignoreEntries = []string{
	"/.claude/*",
	"!/.claude/settings.json",
	"!/.claude/bin/",
}

func configureGitignore(cfg *Config) {
	path := filepath.Join(cfg.ProjectDir, ".gitignore")

	var existingLines []string
	if data, err := os.ReadFile(path); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			existingLines = append(existingLines, strings.TrimSpace(line))
		}
	}

	var missing []string
	for _, entry := range gitignoreEntries {
		if !slices.Contains(existingLines, entry) {
			missing = append(missing, entry)
		}
	}

	if len(missing) == 0 {
		fmt.Println("Already present   : .gitignore entries")
		return
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: could not update .gitignore: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	// strings.Split on a file ending with "\n" produces a trailing "" element,
	// so a non-empty last element means the file has no trailing newline.
	if len(existingLines) > 0 && existingLines[len(existingLines)-1] != "" {
		fmt.Fprintln(f)
	}
	for _, entry := range missing {
		fmt.Fprintln(f, entry)
	}
	fmt.Printf("Updated           : .gitignore (+%d entries)\n", len(missing))
}

// ─── JSON helpers ─────────────────────────────────────────────────────────────

// readJSONFile loads a JSON file into a map keyed by top-level field name.
// Using json.RawMessage as values preserves fields togi doesn't know about,
// so configure operations never discard unrelated settings.
// Returns an empty map if the file does not exist.
func readJSONFile(path string) (map[string]json.RawMessage, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return make(map[string]json.RawMessage), nil
	}
	if err != nil {
		return nil, err
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	return m, nil
}

func writeJSONFile(path string, m map[string]json.RawMessage) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	// Write to a temp file then rename atomically. A crash mid-write would
	// otherwise leave the settings file empty or partially written.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
