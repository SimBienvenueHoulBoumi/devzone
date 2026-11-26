package state

import (
	"os"
	"path/filepath"
	"testing"
)

// TestShellMigrateGlobalGoEquivalent checks frozen one-time move of the former
// global state file, with a fake kubectl (never a real cluster), taken from
// the shell comparison before state.sh was removed.
func TestShellMigrateGlobalGoEquivalent(t *testing.T) {
	dir := t.TempDir()
	home := filepath.Join(dir, "gohome")
	path := filepath.Join(dir, "go.modules")
	global := "ai=on\nplatform=gitlab\n"
	writeStateFile(t, filepath.Join(home, ".config", "devzone", "modules"), global)
	modules := defaultModules()
	var warns []string
	kube := func(name string, args ...string) (string, string, error) { return "", "", os.ErrNotExist }
	if err := At(path).Init(modules, kube, home, nil, func(m string) { warns = append(warns, m) }); err != nil {
		t.Fatalf("code 1, want frozen code 0: %v", err)
	}
	assertFile(t, path, global)
	if _, err := os.Stat(filepath.Join(home, ".config", "devzone", "modules")); !os.IsNotExist(err) {
		t.Fatalf("global remains (%v)", err)
	}
	if len(warns) != 0 { // no output, no warning
		t.Fatalf("unexpected output %q", warns)
	}
}
