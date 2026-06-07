package main

import (
	"os"
	"path/filepath"
	"testing"
)

// ─── sanitizeSlug ─────────────────────────────────────────────────────────────

func TestSanitizeSlug(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"hello-world", "hello-world"},
		{"Hello World", "hello-world"},
		{"foo_bar", "foo-bar"},
		{"  leading-spaces  ", "leading-spaces"},
		{"UPPERCASE", "uppercase"},
		{"123-valid", "123-valid"},
		{"", "unknown"},
		{"---", "unknown"},
		{string(make([]byte, 100)), "unknown"}, // all zero bytes → stripped
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := sanitizeSlug(tt.input)
			if got != tt.expected {
				t.Errorf("sanitizeSlug(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestSanitizeSlug_TruncatesAt64(t *testing.T) {
	long := "a"
	for range 100 {
		long += "b"
	}
	got := sanitizeSlug(long)
	if len(got) > 64 {
		t.Errorf("len = %d, want <= 64", len(got))
	}
}

// ─── sanitizeSessionID ────────────────────────────────────────────────────────

func TestSanitizeSessionID(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"abc-123", "abc-123"},
		{"abc_123", "abc_123"},
		{"abc 123", "abc_123"},
		{"abc/123", "abc_123"},
		{"abc.123", "abc_123"},
		{"", "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := sanitizeSessionID(tt.input)
			if got != tt.expected {
				t.Errorf("sanitizeSessionID(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

func TestSanitizeSessionID_TruncatesAt64(t *testing.T) {
	long := ""
	for range 100 {
		long += "a"
	}
	got := sanitizeSessionID(long)
	if len(got) > 64 {
		t.Errorf("len = %d, want <= 64", len(got))
	}
}

// ─── validateDocGap ───────────────────────────────────────────────────────────

func TestValidateDocGap(t *testing.T) {
	projectDir := t.TempDir()

	tests := []struct {
		name    string
		docGap  string
		wantOK  bool
		wantRel string
	}{
		{"valid relative path", "docs/api.md", true, "docs/api.md"},
		{"nested valid path", "a/b/c.md", true, "a/b/c.md"},
		{"empty", "", false, ""},
		{"path traversal", "../../etc/passwd", false, ""},
		// filepath.Join(projectDir, "/abs") produces projectDir+"/abs" in Go,
		// so an absolute-looking docGap resolves safely under the project dir.
		{"absolute path resolves under project", "/docs/api.md", true, "docs/api.md"},
		// All path components starting with "." are rejected, including filenames.
		{"hidden directory", ".hidden/file.md", false, ""},
		{"nested hidden directory", "docs/.hidden/file.md", false, ""},
		{"hidden file rejected", "docs/.hidden-file.md", false, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rel, ok := validateDocGap(tt.docGap, projectDir)
			if ok != tt.wantOK {
				t.Errorf("ok = %v, want %v", ok, tt.wantOK)
			}
			if ok && rel != tt.wantRel {
				t.Errorf("rel = %q, want %q", rel, tt.wantRel)
			}
		})
	}
}

// ─── acquireLock / releaseLock ────────────────────────────────────────────────

func TestAcquireLock_Success(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".test.lock")
	f := acquireLock(path)
	if f == nil {
		t.Fatal("expected lock to be acquired")
	}
	releaseLock(f, path)
}

func TestAcquireLock_DoubleLockFails(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".test.lock")
	f1 := acquireLock(path)
	if f1 == nil {
		t.Fatal("first lock should succeed")
	}
	defer releaseLock(f1, path)

	f2 := acquireLock(path)
	if f2 != nil {
		releaseLock(f2, path)
		t.Error("second lock should fail while first is held")
	}
}

func TestAcquireLock_ReacquireAfterRelease(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".test.lock")

	f1 := acquireLock(path)
	if f1 == nil {
		t.Fatal("first lock should succeed")
	}
	releaseLock(f1, path)

	f2 := acquireLock(path)
	if f2 == nil {
		t.Fatal("lock should be reacquirable after release")
	}
	releaseLock(f2, path)
}

func TestAcquireLock_LockFileRemains(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".test.lock")
	f := acquireLock(path)
	if f == nil {
		t.Fatal("lock should succeed")
	}
	releaseLock(f, path)

	// Lock file should persist after release to avoid the inode-reuse race.
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Error("lock file should remain after release")
	}
}
