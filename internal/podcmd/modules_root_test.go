package podcmd

import (
	"os"
	"path/filepath"
	"testing"
)

// TestDevzoneRoot checks that the devzone folder never depends on the current directory.
func TestDevzoneRoot(t *testing.T) {
	root := t.TempDir()
	script := filepath.Join(root, ".devcontainer", "devzone")
	if err := os.MkdirAll(filepath.Dir(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/usr/bin/env bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_POD_SCRIPT", script)
	t.Setenv("DEVZONE_ROOT", "")
	if got := devzoneRoot(); got != root {
		t.Fatalf("root = %q, want %q", got, root)
	}
	t.Setenv("DEVZONE_ROOT", "/elsewhere")
	if got := devzoneRoot(); got != "/elsewhere" {
		t.Fatalf("root = %q, want DEVZONE_ROOT", got)
	}
}
