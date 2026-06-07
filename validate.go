package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

var (
	slugRe      = regexp.MustCompile(`[^a-z0-9-]+`)
	sessionIDRe = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)
)

// sanitizeSlug strips any character that is not a lowercase letter, digit, or hyphen,
// and truncates to 64 characters. Slugs come from LLM output and are used as filenames.
func sanitizeSlug(slug string) string {
	slug = strings.ToLower(slug)
	slug = slugRe.ReplaceAllString(slug, "-")
	slug = strings.Trim(slug, "-")
	if len(slug) > 64 {
		slug = slug[:64]
	}
	if slug == "" {
		return "unknown"
	}
	return slug
}

// sanitizeSessionID strips characters that are unsafe in directory names and truncates
// to 64 characters. Session IDs come from Claude Code hook input (untrusted).
func sanitizeSessionID(id string) string {
	id = sessionIDRe.ReplaceAllString(id, "_")
	if len(id) > 64 {
		id = id[:64]
	}
	if id == "" {
		return "unknown"
	}
	return id
}

// validateDocGap returns the cleaned relative path (from projectDir) if safe, false otherwise.
// Rejected if the path escapes projectDir or passes through any hidden directory component.
func validateDocGap(docGap, projectDir string) (string, bool) {
	if docGap == "" {
		return "", false
	}
	clean := filepath.Clean(filepath.Join(projectDir, docGap))
	rel, err := filepath.Rel(projectDir, clean)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		if strings.HasPrefix(part, ".") {
			return "", false
		}
	}
	return rel, true
}

// acquireLock takes a non-blocking exclusive flock on the lock file.
// Returns the open file on success, nil if the lock is already held.
// The lock is automatically released by the OS if the process crashes.
func acquireLock(path string) *os.File {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil
	}
	return f
}

func releaseLock(f *os.File, _ string) {
	// Closing the fd releases the flock automatically. Do NOT os.Remove here:
	// removing after LOCK_UN creates an inode-reuse race where two processes
	// can end up holding the lock simultaneously on different inodes.
	f.Close() //nolint:errcheck
}
