package podcmd

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// programFixture builds an npm copy and an image copy of devzone in temporary
// folders, plus a PATH value naming both folders; the process PATH is untouched.
func programFixture(t *testing.T) (npm, image, pathValue string) {
	t.Helper()
	base := t.TempDir()
	npm = filepath.Join(base, "npm", "bin")
	image = filepath.Join(base, "image", "bin")
	for _, dir := range []string{npm, image} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "devzone"), []byte("fixture\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	pathValue = strings.Join([]string{npm, image}, string(os.PathListSeparator))
	return npm, image, pathValue
}

// TestShadowedProgramWarning checks that the warning names the copy that wins
// and the repair command, and stays silent when the image program wins, when
// no devzone is found, or when the lookup fails.
func TestShadowedProgramWarning(t *testing.T) {
	npm, image, both := programFixture(t)
	npmFile, imageFile := filepath.Join(npm, "devzone"), filepath.Join(image, "devzone")
	t.Run("npm copy first", func(t *testing.T) {
		got := shadowedProgramWarning(both, lookPathInValue, imageFile)
		contains(t, got, npmFile, imageFile, "npm uninstall -g devzone")
	})
	t.Run("image first", func(t *testing.T) {
		pathValue := strings.Join([]string{image, npm}, string(os.PathListSeparator))
		if got := shadowedProgramWarning(pathValue, lookPathInValue, imageFile); got != "" {
			t.Fatalf("image program warned: %q", got)
		}
	})
	t.Run("no devzone in PATH", func(t *testing.T) {
		pathValue := filepath.Join(t.TempDir(), "empty")
		if got := shadowedProgramWarning(pathValue, lookPathInValue, imageFile); got != "" {
			t.Fatalf("empty PATH warned: %q", got)
		}
	})
	t.Run("lookup failure", func(t *testing.T) {
		look := func(string, string) (string, error) { return "", errors.New("not found") }
		if got := shadowedProgramWarning(both, look, imageFile); got != "" {
			t.Fatalf("failed lookup warned: %q", got)
		}
	})
}

// TestStatusProgramLineUsesInjectedLookup checks that status prints the line
// from the injected lookup and prints nothing when the image program wins.
func TestStatusProgramLineUsesInjectedLookup(t *testing.T) {
	npm, _, _ := programFixture(t)
	npmFile := filepath.Join(npm, "devzone")
	old := programLookPath
	t.Cleanup(func() { programLookPath = old })
	_, _, _, r := statusFixture(t)
	programLookPath = func(string, string) (string, error) { return npmFile, nil }
	contains(t, runStatusText(t, r), "  ⚠ program", npmFile, "npm uninstall -g devzone")
	programLookPath = func(string, string) (string, error) { return imageProgram(), nil }
	if got := runStatusText(t, r); strings.Contains(got, "npm uninstall -g devzone") {
		t.Fatalf("image program warned: %s", got)
	}
}
