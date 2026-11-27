package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsDevzoneGuard checks when a watcher command is accepted: an explicit
// state folder accepts it anywhere, otherwise the folder must be a devzone one.
func TestPortsDevzoneGuard(t *testing.T) {
	t.Run("explicit state folder outside devzone is accepted", func(t *testing.T) {
		outside := t.TempDir()
		t.Setenv("DEVZONE_ROOT", outside)
		t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", filepath.Join(t.TempDir(), "state"))
		var out bytes.Buffer
		if portsDevzoneGuard(&out) {
			t.Fatalf("refused with DEVZONE_PORTS_WORKSPACE_DIR set: %q", out.String())
		}
		if out.Len() != 0 {
			t.Fatalf("output = %q, want none", out.String())
		}
	})

	t.Run("no state folder outside devzone is refused", func(t *testing.T) {
		outside := t.TempDir()
		t.Setenv("DEVZONE_ROOT", outside)
		t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", "")
		var out bytes.Buffer
		if !portsDevzoneGuard(&out) {
			t.Fatal("accepted outside a devzone folder without DEVZONE_PORTS_WORKSPACE_DIR")
		}
		if want := "is not a devzone folder"; !strings.Contains(out.String(), want) {
			t.Fatalf("output = %q, want it to contain %q", out.String(), want)
		}
		if !strings.Contains(out.String(), outside) {
			t.Fatalf("output = %q, want the folder %q", out.String(), outside)
		}
	})

	t.Run("no state folder inside devzone is accepted", func(t *testing.T) {
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, ".devzone.version"), []byte("7.0.1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		folder := filepath.Join(root, "projet")
		if err := os.Mkdir(folder, 0o755); err != nil {
			t.Fatal(err)
		}
		t.Setenv("DEVZONE_ROOT", folder)
		t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", "")
		var out bytes.Buffer
		if portsDevzoneGuard(&out) {
			t.Fatalf("refused inside a devzone folder: %q", out.String())
		}
	})
}
