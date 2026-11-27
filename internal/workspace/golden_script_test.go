package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// goldenMismatch returns the reason why got differs from a reference, or an
// empty string when they are equal. A reference checked out with CRLF on a
// Windows workstation prints like the LF text but holds different bytes, so
// it gets its own reason: the cause is the checkout, not a changed script.
func goldenMismatch(got, want string) string {
	if got == want {
		return ""
	}
	if strings.ReplaceAll(want, "\r\n", "\n") == got {
		return "the reference file has CRLF line endings from the checkout"
	}
	return "the bytes differ"
}

// goldenCheck compares got with the reference file testdata/<name>; with UPDATE_GOLDEN=1 it writes the file instead, to change a reference on purpose.
func goldenCheck(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if reason := goldenMismatch(got, string(want)); reason != "" {
		t.Fatalf("%s differs from the reference file (%s; UPDATE_GOLDEN=1 go test to change it on purpose):\n%s\nwant:\n%s", name, reason, got, want)
	}
}

// TestGoldenCheckDetectsCRLFReference reproduces the Windows CI failure on
// Linux: a CRLF reference file differs from the LF script although both print
// the same lines. It also checks that a real content change keeps a different
// reason, so the diagnostic cannot hide a script that was really modified.
func TestGoldenCheckDetectsCRLFReference(t *testing.T) {
	got := copyGuardScript
	if reason := goldenMismatch(got, got); reason != "" {
		t.Fatalf("identical text reported %q", reason)
	}
	crlf := strings.ReplaceAll(got, "\n", "\r\n")
	if reason := goldenMismatch(got, crlf); !strings.Contains(reason, "CRLF") {
		t.Fatalf("CRLF reference reported %q, want a CRLF reason", reason)
	}
	if reason := goldenMismatch(got, got+"\n"); reason == "" || strings.Contains(reason, "CRLF") {
		t.Fatalf("changed reference reported %q, want a plain difference", reason)
	}
}

// TestCopyGuardScriptGolden checks that copyGuardScript matches the reference
// file testdata/copy_guard_script.txt
func TestCopyGuardScriptGolden(t *testing.T) {
	goldenCheck(t, "copy_guard_script.txt", copyGuardScript)
}

// TestCloneScriptGolden checks that cloneScript matches the reference file
// testdata/clone_script.txt
func TestCloneScriptGolden(t *testing.T) {
	goldenCheck(t, "clone_script.txt", cloneScript)
}

// TestLegacyScriptGolden checks that podScript still matches the pod script of
// the removed shell helper, kept as testdata/legacy_script.txt.
func TestLegacyScriptGolden(t *testing.T) {
	goldenCheck(t, "legacy_script.txt", podScript)
}
