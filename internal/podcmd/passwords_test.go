package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestHandlesPasswords checks that the pod command is registered and no longer
// delegated to the shell entry point.
func TestHandlesPasswords(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := Run([]string{"handles", "passwords"}, &out, &errOut); code != 0 {
		t.Fatalf("handles: code %d", code)
	}
}

// passwordFixture builds a disposable root with one dummy account.
func passwordFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "workspace", ".gitlab")
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "root-password"), []byte("secret-not-printed"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_ROOT", root)
	return root
}

// TestPasswordsCommandPrintsOnlyPath checks that regeneration is silent apart
// from the path, and that no secret reaches either output stream.
func TestPasswordsCommandPrintsOnlyPath(t *testing.T) {
	root := passwordFixture(t)
	var out, errOut bytes.Buffer
	if code := Run([]string{"passwords"}, &out, &errOut); code != 0 {
		t.Fatalf("code %d, err %q", code, errOut.String())
	}
	want := filepath.Join(root, ".password") + "\n"
	if out.String() != want {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
	if errOut.Len() != 0 {
		t.Fatalf("err = %q", errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".password")); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String()+errOut.String(), "secret-not-printed") {
		t.Fatal("secret printed")
	}
}

// TestPasswordsSubcommands covers the silent regeneration and path calls used
// by the shell callers, and the refusal of an unknown argument.
func TestPasswordsSubcommands(t *testing.T) {
	root := passwordFixture(t)
	target := filepath.Join(root, ".password")
	for _, args := range [][]string{{"passwords", "regenerate"}, {"passwords", "path"}} {
		var out, errOut bytes.Buffer
		if code := Run(args, &out, &errOut); code != 0 {
			t.Fatalf("%v: code %d, err %q", args, code, errOut.String())
		}
	}
	var out, errOut bytes.Buffer
	if code := Run([]string{"passwords", "wrong"}, &out, &errOut); code != 1 {
		t.Fatalf("unknown: code %d", code)
	}
	if !strings.Contains(errOut.String(), "regenerate | path") {
		t.Fatalf("err = %q", errOut.String())
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatal(err)
	}
}

// TestPasswordsWithoutRoot refuses to write in the current folder when the
// devzone root cannot be resolved.
func TestPasswordsWithoutRoot(t *testing.T) {
	t.Setenv("DEVZONE_ROOT", "")
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	previous := defaultScript
	defaultScript = filepath.Join(t.TempDir(), "absent")
	defer func() { defaultScript = previous }()
	var out, errOut bytes.Buffer
	if code := Run([]string{"passwords"}, &out, &errOut); code != 1 {
		t.Fatalf("code %d", code)
	}
	if out.Len() != 0 {
		t.Fatalf("out = %q", out.String())
	}
}
