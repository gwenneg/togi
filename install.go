package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const togiRepo = "gwenneg/togi"

// httpClient is shared across all outbound calls in install.go.
// A 60-second timeout prevents indefinite hangs, and redirect checks restrict
// downloads to the expected GitHub hostnames.
var httpClient = &http.Client{
	Timeout: 60 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		allowed := map[string]bool{
			"api.github.com":               true,
			"github.com":                   true,
			"objects.githubusercontent.com": true,
		}
		if !allowed[req.URL.Host] {
			return fmt.Errorf("redirect to untrusted host %q blocked", req.URL.Host)
		}
		if len(via) >= 5 {
			return fmt.Errorf("too many redirects")
		}
		return nil
	},
}

// install checks for a newer version of the togi binary and, unless --check is passed,
// downloads, verifies, and installs it. Every step is printed so the user can audit
// what happened. Sensitive operations (download, install) are only performed when
// --check is not set — callers (skills) must obtain user consent before invoking
// without --check.
func install(cfg *Config, checkOnly bool) {
	fmt.Println("─── togi install ───────────────────────────────────")

	fmt.Printf("Installed version : %s\n", version)

	fmt.Print("Fetching latest release... ")
	release, err := latestRelease()
	if err != nil {
		fmt.Println("failed.")
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(release.TagName)

	if stripV(version) == stripV(release.TagName) {
		fmt.Println("Already up to date.")
		return
	}

	fmt.Printf("Update available  : %s → %s\n", version, release.TagName)

	if release.Body != "" {
		fmt.Println("────────────────────────────────────────────────────")
		fmt.Println(formatChangelog(release.Body, release.TagName))
		fmt.Println("────────────────────────────────────────────────────")
	}

	if checkOnly {
		fmt.Println("Run without --check to install the update.")
		os.Exit(2) // exit code 2 = update available
	}

	fmt.Println("────────────────────────────────────────────────────")

	osName := runtime.GOOS
	arch := runtime.GOARCH
	binaryName := fmt.Sprintf("togi-%s-%s", osName, arch)
	fmt.Printf("Platform          : %s/%s (%s)\n", osName, arch, binaryName)

	if err := doInstall(cfg, release.TagName, binaryName); err != nil {
		fmt.Fprintf(os.Stderr, "ERROR: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("────────────────────────────────────────────────────")
	fmt.Printf("togi updated to %s.\n", release.TagName)
}

// doInstall downloads, verifies, and installs the binary. It returns an error
// rather than calling os.Exit so that defer cleanup runs correctly.
func doInstall(cfg *Config, tag, binaryName string) error {
	tmpDir, err := os.MkdirTemp("", "togi-install-*")
	if err != nil {
		return fmt.Errorf("could not create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	base := fmt.Sprintf("https://github.com/%s/releases/download/%s", togiRepo, tag)
	binaryPath := filepath.Join(tmpDir, "togi")
	sumsPath := filepath.Join(tmpDir, "sha256sums.txt")

	fmt.Printf("Downloading binary: %s/%s... ", base, binaryName)
	if err := downloadFile(base+"/"+binaryName, binaryPath); err != nil {
		fmt.Println("failed.")
		return err
	}
	fmt.Println("OK")

	fmt.Printf("Downloading sums  : %s/sha256sums.txt... ", base)
	if err := downloadFile(base+"/sha256sums.txt", sumsPath); err != nil {
		fmt.Println("failed.")
		return err
	}
	fmt.Println("OK")

	fmt.Print("Verifying build attestation (gh attestation verify)... ")
	cmd := exec.Command("gh", "attestation", "verify", binaryPath, "--repo", togiRepo)
	out, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Println("FAILED.")
		fmt.Fprintf(os.Stderr, "%s\n", strings.TrimSpace(string(out)))
		return fmt.Errorf("attestation verification failed")
	}
	fmt.Println("OK")

	fmt.Print("Verifying SHA-256 checksum... ")
	expected, err := extractChecksum(sumsPath, binaryName)
	if err != nil {
		fmt.Println("FAILED.")
		return err
	}
	actual, err := sha256File(binaryPath)
	if err != nil {
		fmt.Println("FAILED.")
		return fmt.Errorf("could not compute checksum: %w", err)
	}
	if expected != actual {
		fmt.Println("FAILED.")
		return fmt.Errorf("checksum mismatch.\n  Expected: %s\n  Actual:   %s", expected, actual)
	}
	fmt.Printf("OK (%s)\n", actual[:16]+"…")

	dest := filepath.Join(cfg.ProjectDir, ".claude", "bin", "togi")
	fmt.Printf("Installing to     : %s... ", dest)
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		fmt.Println("FAILED.")
		return err
	}
	// os.Rename is atomic on the same filesystem; fall back to copy if cross-device.
	if err := os.Rename(binaryPath, dest); err != nil {
		if err := copyFile(binaryPath, dest); err != nil {
			fmt.Println("FAILED.")
			return err
		}
	}
	if err := os.Chmod(dest, 0755); err != nil {
		fmt.Println("FAILED.")
		return err
	}
	fmt.Println("OK")
	return nil
}

func stripV(tag string) string {
	return strings.TrimPrefix(tag, "v")
}

// formatChangelog renders the release body, capping list items at 10.
// A link to the full release is always appended.
func formatChangelog(body, tag string) string {
	const maxItems = 10

	lines := strings.Split(strings.TrimSpace(body), "\n")
	var kept []string
	items := 0

	for _, line := range lines {
		if isListItem(strings.TrimSpace(line)) {
			items++
			if items > maxItems {
				break
			}
		}
		kept = append(kept, line)
	}

	result := strings.Join(kept, "\n")
	if items > maxItems {
		result += "\n…"
	}
	return result + fmt.Sprintf("\n\nhttps://github.com/%s/releases/tag/%s", togiRepo, tag)
}

// isListItem reports whether a trimmed line is a Markdown list item
// (unordered: "- ", "* ", "+ "; ordered: "1. ", "2. ", etc.)
func isListItem(line string) bool {
	if len(line) < 2 {
		return false
	}
	switch line[:2] {
	case "- ", "* ", "+ ":
		return true
	}
	for i, ch := range line {
		if ch >= '0' && ch <= '9' {
			continue
		}
		return i > 0 && ch == '.' && strings.HasPrefix(line[i:], ". ")
	}
	return false
}

// githubRelease holds the fields we need from the GitHub releases API response.
type githubRelease struct {
	TagName string `json:"tag_name"`
	Body    string `json:"body"` // release notes in Markdown
}

// latestRelease fetches the latest release metadata from the GitHub API.
func latestRelease() (githubRelease, error) {
	resp, err := httpClient.Get("https://api.github.com/repos/" + togiRepo + "/releases/latest")
	if err != nil {
		return githubRelease{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return githubRelease{}, fmt.Errorf("GitHub API returned HTTP %d", resp.StatusCode)
	}
	var r githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
		return githubRelease{}, err
	}
	if r.TagName == "" {
		return githubRelease{}, fmt.Errorf("empty tag_name in GitHub API response")
	}
	if !validTag(r.TagName) {
		return githubRelease{}, fmt.Errorf("unexpected tag format: %q", r.TagName)
	}
	return r, nil
}

// validTag ensures the tag from the GitHub API is a plain semver string before
// it is interpolated into download URLs.
func validTag(tag string) bool {
	if len(tag) == 0 || len(tag) > 32 {
		return false
	}
	for _, ch := range tag {
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || ch == 'v' || ch == '.' || ch == '-') {
			return false
		}
	}
	return true
}

const maxDownloadBytes = 50 * 1024 * 1024 // 50 MB

// downloadFile fetches url and writes the response body to dest.
// Downloads are capped at maxDownloadBytes; an error is returned if the limit is exceeded.
func downloadFile(url, dest string) error {
	resp, err := httpClient.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d for %s", resp.StatusCode, url)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	if _, err = io.Copy(f, io.LimitReader(resp.Body, maxDownloadBytes)); err != nil {
		f.Close()
		return err
	}
	// Detect silent truncation: if there are bytes remaining, the file exceeded the limit.
	var probe [1]byte
	if n, _ := resp.Body.Read(probe[:]); n > 0 {
		f.Close()
		return fmt.Errorf("download exceeds %d MB limit", maxDownloadBytes/1024/1024)
	}
	return f.Close()
}

// extractChecksum finds the SHA-256 hex string for binaryName in a sha256sums.txt file.
func extractChecksum(sumsPath, binaryName string) (string, error) {
	f, err := os.Open(sumsPath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 2 && fields[1] == binaryName {
			sum := fields[0]
			if len(sum) != 64 {
				return "", fmt.Errorf("invalid checksum length for %s: got %d characters", binaryName, len(sum))
			}
			if _, err := hex.DecodeString(sum); err != nil {
				return "", fmt.Errorf("invalid checksum hex for %s: %w", binaryName, err)
			}
			return sum, nil
		}
	}
	if err := sc.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("no checksum entry for %s in sha256sums.txt", binaryName)
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// copyFile is used as a fallback when os.Rename fails across filesystem boundaries.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst) // remove partial file so the next run starts clean
		return err
	}
	return out.Close()
}
