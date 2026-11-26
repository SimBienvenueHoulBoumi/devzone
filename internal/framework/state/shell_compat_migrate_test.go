package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestShellMigrateGlobalGoEquivalent checks the one-time move of the former
// global state file, identical for shell and Go, with a fake kubectl.
func TestShellMigrateGlobalGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	writeShellFake(t, filepath.Join(bin, "kubectl"), "#!/usr/bin/env bash\nexit 1\n")
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	shellHome := filepath.Join(dir, "shellhome")
	goHome := filepath.Join(dir, "gohome")
	shellStatePath := filepath.Join(dir, "shell.modules")
	goStatePath := filepath.Join(dir, "go.modules")
	global := "ai=on\nplatform=gitlab\n"
	writeShellFake(t, filepath.Join(shellHome, ".config", "devzone", "modules"), global)
	writeShellFake(t, filepath.Join(goHome, ".config", "devzone", "modules"), global)
	modules := []string{"ai", "kubernetes", "gitlab", "postgres", "argocd", "mysql"}
	program := `. "$1"; ETAT="$2"; state_init "$@"`
	t.Setenv("HOME", shellHome)
	shellOut, shellCode := shellCommandArgs(t, script, shellStatePath, program, modules)
	t.Setenv("HOME", goHome)
	var warns []string
	goCode := numericCode(At(goStatePath).Init(modules, shellRunner(), goHome, nil, func(m string) { warns = append(warns, m) }))
	compareCodes(t, "migrate global", shellCode, goCode)
	compareStateBytes(t, shellStatePath, goStatePath)
	if _, err := os.Stat(filepath.Join(shellHome, ".config", "devzone", "modules")); !os.IsNotExist(err) {
		t.Fatalf("shell global remains: %v", err)
	}
	if _, err := os.Stat(filepath.Join(goHome, ".config", "devzone", "modules")); !os.IsNotExist(err) {
		t.Fatalf("Go global remains: %v", err)
	}
	if strings.TrimSpace(shellOut) != "" {
		t.Fatalf("unexpected shell output: %q", shellOut)
	}
}
