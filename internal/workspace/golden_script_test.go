package workspace

import (
	"os"
	"path/filepath"
	"testing"
)

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
	if got != string(want) {
		t.Fatalf("%s differs from the reference file (UPDATE_GOLDEN=1 go test to change it on purpose):\n%s\nwant:\n%s", name, got, want)
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
