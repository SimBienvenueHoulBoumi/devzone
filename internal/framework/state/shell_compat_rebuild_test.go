package state

import (
	"os"
	"path/filepath"
	"testing"
)

// TestShellRebuildGoEquivalent checks state_rebuild vs State.Rebuild with a fake
// kubectl, comparing the rebuilt state and exit code.
func TestShellRebuildGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	writeShellFake(t, filepath.Join(bin, "kubectl"), `#!/usr/bin/env bash
case "$*" in
    get\ namespaces*) printf 'namespace/devzone-postgres\nnamespace/devzone-gitlab\n' ;;
    *"config view"*devzone*) echo kind-devzone ;;
    *"config get-contexts"*) printf 'devzone\ndocker-desktop\n' ;;
    *docker-desktop*) echo kind-devzone ;;
    *) exit 1 ;;
esac
exit 0
`)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(dir, "host.config"))
	t.Setenv("HOME", dir)
	modules := []string{"ai", "kubernetes", "gitlab", "postgres", "argocd", "mysql"}
	shellPath, goPath := stateCopies(t, "")
	_, shellCode := shellState(t, script, shellPath, `state_rebuild "${@:3}"`, modules...)
	s := At(goPath)
	var warns []string
	_, err := s.Rebuild(modules, shellRunner(), func(m string) { warns = append(warns, m) })
	goCode := numericCode(err)
	compareCodes(t, "state_rebuild", shellCode, goCode)
	compareStateBytes(t, shellPath, goPath)
}
