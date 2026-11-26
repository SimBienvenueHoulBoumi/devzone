package command

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// TestLegacyUninstallerRunsOldScript checks that an older devzone folder keeps
// its own removal procedure, with the command name of the shell launcher and
// without touching the environment of the next command.
func TestLegacyUninstallerRunsOldScript(t *testing.T) {
	requireBash(t)
	root := t.TempDir()
	script := filepath.Join(root, "uninstall.sh")
	if err := os.WriteFile(script, []byte("printf '%s\\n' \"$DEVZONE_COMMAND\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := legacyUninstaller(root); got != script {
		t.Fatalf("uninstaller = %q, want %q", got, script)
	}
	t.Setenv("DEVZONE_COMMAND", "")
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &errOut}
	if code := runLegacyUninstaller(ctx, script); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if out.String() != "devzone uninstall\n" {
		t.Fatalf("stdout = %q", out.String())
	}
	if got := os.Getenv("DEVZONE_COMMAND"); got != "" {
		t.Fatalf("DEVZONE_COMMAND not restored: %q", got)
	}
}

// TestLegacyUninstallerAbsent checks that a current devzone folder has no old
// script to run, so the Go removal plan applies.
func TestLegacyUninstallerAbsent(t *testing.T) {
	if got := legacyUninstaller(t.TempDir()); got != "" {
		t.Fatalf("uninstaller = %q, want none", got)
	}
}
