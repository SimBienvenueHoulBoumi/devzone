package createmode

import (
	"os"
	"path/filepath"
	"testing"
)

// TestWriteNewFile checks that a folder without a module file receives only
// the workspace line.
func TestWriteNewFile(t *testing.T) {
	folder := filepath.Join(t.TempDir(), "folder")
	if err := os.Mkdir(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Write(folder, "kubernetes"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(folder, ".devzone.modules"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "workspace=kubernetes\n" {
		t.Fatalf("modules = %q", data)
	}
	if _, err := os.Stat(filepath.Join(folder, ".devzone.modules.tmp")); !os.IsNotExist(err) {
		t.Fatalf("temporary file left behind: %v", err)
	}
}

// TestWriteReplacesMode checks that other module lines survive and that the
// former workspace line is replaced, without a temporary file left behind.
func TestWriteReplacesMode(t *testing.T) {
	folder := t.TempDir()
	path := filepath.Join(folder, ".devzone.modules")
	if err := os.WriteFile(path, []byte("argocd=on\nworkspace=local\nports=auto\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Write(folder, "kubernetes"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "argocd=on\nports=auto\nworkspace=kubernetes\n"
	if string(data) != want {
		t.Fatalf("modules = %q; want %q", data, want)
	}
}
