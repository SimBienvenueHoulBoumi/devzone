package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestTestGitlabUsesDevzoneRoot checks that the e2e command reads its secrets
// from the devzone root of the shell entry point, never from the current
// folder, as postgres does.
func TestTestGitlabUsesDevzoneRoot(t *testing.T) {
	root := t.TempDir()
	current := t.TempDir()
	before, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(before) })
	if err := os.Chdir(current); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_HOSTS", filepath.Join(root, "hosts"))
	t.Setenv("TMPDIR", root)
	var out, errOut strings.Builder
	ctx := &cli.Context{Out: &out, Err: &errOut, Runner: fake.New()}
	if code := runTestGitlab(ctx); code == 0 {
		t.Fatal("code = 0 without a root token")
	}
	token := filepath.Join(root, "workspace", ".gitlab", "root-token")
	if !strings.Contains(out.String(), token) {
		t.Errorf("output = %q, want the token path under %s", out.String(), root)
	}
	if strings.Contains(out.String(), current) {
		t.Errorf("the current folder was used: %q", out.String())
	}
}

// TestTestGitlabRootFromScript checks the root computed from the shell entry
// point when DEVZONE_ROOT is not set.
func TestTestGitlabRootFromScript(t *testing.T) {
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
		t.Fatalf("devzoneRoot = %q, want %q", got, root)
	}
	if got := codeRoot(); got != filepath.Dir(script) {
		t.Fatalf("codeRoot = %q", got)
	}
}
