package bashbridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// makeEntry creates manage/devzone under folder and returns its path
func makeEntry(t *testing.T, folder string) string {
	t.Helper()
	path := filepath.Join(folder, "manage", "devzone")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("exit 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestFindEnvOverride(t *testing.T) {
	path := writeScript(t, "exit 0\n")
	got, err := find(path, "", "")
	if err != nil || got != path {
		t.Fatalf("find = %q, %v; want %q", got, err, path)
	}
}

func TestFindEnvOverrideMissing(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "absent")
	_, err := find(missing, "", "")
	if err == nil || !strings.HasPrefix(err.Error(), "bash entry point not found") {
		t.Fatalf("error = %v, want the not found message", err)
	}
}

func TestFindSearchOrder(t *testing.T) {
	t.Run("binary folder first", func(t *testing.T) {
		root := t.TempDir()
		exeDir := filepath.Join(root, "bin")
		want := makeEntry(t, exeDir)
		makeEntry(t, root)
		makeEntry(t, filepath.Join(root, "work"))
		got, err := find("", exeDir, filepath.Join(root, "work"))
		if err != nil || got != want {
			t.Fatalf("find = %q, %v; want %q", got, err, want)
		}
	})
	t.Run("parent folder second", func(t *testing.T) {
		root := t.TempDir()
		want := makeEntry(t, root)
		makeEntry(t, filepath.Join(root, "work"))
		got, err := find("", filepath.Join(root, "bin"), filepath.Join(root, "work"))
		if err != nil || got != want {
			t.Fatalf("find = %q, %v; want %q", got, err, want)
		}
	})
	t.Run("working folder last", func(t *testing.T) {
		root := t.TempDir()
		want := makeEntry(t, filepath.Join(root, "work"))
		got, err := find("", filepath.Join(root, "bin"), filepath.Join(root, "work"))
		if err != nil || got != want {
			t.Fatalf("find = %q, %v; want %q", got, err, want)
		}
	})
}

func TestFindAbsent(t *testing.T) {
	_, err := find("", t.TempDir(), t.TempDir())
	if err == nil || err.Error() != "bash entry point not found: set DEVZONE_BASH_ENTRY" {
		t.Fatalf("error = %v, want the not found message", err)
	}
}
