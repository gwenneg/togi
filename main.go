package main

import (
	"fmt"
	"io"
	"os"
)

var version = "dev" // overridden at build time via -ldflags "-X main.version=..."

func printHelp() {
	fmt.Printf("togi %s — sharpen AI context docs through friction\n\n", version)
	fmt.Println("Usage: togi <command> [flags]")
	fmt.Println()
	fmt.Println("Hook commands (invoked automatically by Claude Code):")
	fmt.Println("  capture          SessionEnd hook — read transcript, capture friction events in background")
	fmt.Println("  remind           SessionStart hook — show reminder when friction accumulates past threshold")
	fmt.Println()
	fmt.Println("Skill commands (invoked by Claude Code skills):")
	fmt.Println("  install          Download, verify, and install the latest togi binary")
	fmt.Println("  install --check  Check if a newer version is available without downloading (exit 2 if yes)")
	fmt.Println("  enable           Enable friction capture for you only — not committed, not shared")
	fmt.Println("  disable          Disable friction capture for you only — not committed, not shared")
	fmt.Println("  configure        Configure togi hooks and marketplace for the whole team")
	fmt.Println()
	fmt.Println("Other:")
	fmt.Println("  version          Print the installed version")
	fmt.Println("  help             Show this message")
	fmt.Println()
	fmt.Println("Environment variables:")
	fmt.Println("  TOGI_CAPTURE_MODEL      Model used for friction analysis (default: haiku)")
	fmt.Println("  TOGI_ENABLED            Set to 1 to enable friction capture (default: 0)")
	fmt.Println("  TOGI_MAX_TRANSCRIPT_KB  Max transcript size sent to the model in KB (default: 200)")
	fmt.Println("  TOGI_SESSION_THRESHOLD  Sessions before startup reminder appears (default: 3)")
}

func main() {
	if len(os.Args) < 2 {
		printHelp()
		os.Exit(1)
	}

	// version and help don't need config; handle them before Load() to avoid
	// requiring CLAUDE_PROJECT_DIR for simple informational commands.
	switch os.Args[1] {
	case "version":
		fmt.Println(version)
		return
	case "help", "--help", "-h":
		printHelp()
		return
	}

	cfg := Load()

	switch os.Args[1] {
	case "capture":
		input, _ := io.ReadAll(os.Stdin)
		capture(cfg, input)
	case "capture-worker": // internal: spawned by capture to do the actual work in the background
		input, _ := io.ReadAll(os.Stdin)
		captureWorker(cfg, input)
	case "remind":
		remind(cfg)
	case "install":
		checkOnly := len(os.Args) > 2 && os.Args[2] == "--check"
		install(cfg, checkOnly)
	case "enable":
		enable(cfg)
	case "disable":
		disable(cfg)
	case "configure":
		configure(cfg)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		fmt.Fprintln(os.Stderr, "Run 'togi help' for usage.")
		os.Exit(1)
	}
}
