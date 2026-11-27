package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// TestUpdateRefusedOutsideDevzone checks that the update refuses a folder that is
// not a devzone, with the message the shell gave, and changes nothing.
func TestUpdateRefusedOutsideDevzone(t *testing.T) {
	t.Chdir(t.TempDir())
	var out, errOut bytes.Buffer
	code := updateCommand(&cli.Context{Out: &out, Err: &errOut})
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if errOut.String() != "✖ Run this in a devzone folder (.devcontainer not found here).\n" {
		t.Errorf("stderr = %q", errOut.String())
	}
}

// TestUpdateUnknownOptionRefusedFirst checks that an unknown option is reported
// in English, with the usage line, before the folder is looked at.
func TestUpdateUnknownOptionRefusedFirst(t *testing.T) {
	t.Chdir(t.TempDir())
	var out, errOut bytes.Buffer
	code := updateCommand(&cli.Context{Args: []string{"--bogus"}, Out: &out, Err: &errOut})
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	want := "✖ unknown option: --bogus (devzone update [--yes] [--no-rebuild])\n"
	if errOut.String() != want || out.Len() != 0 {
		t.Errorf("stderr = %q, stdout = %q", errOut.String(), out.String())
	}
}

// TestPackageRootFromBashEntry checks that the package root is the folder two
// levels above the bash entry point, and that a missing entry point is an error.
func TestPackageRootFromBashEntry(t *testing.T) {
	t.Setenv(bashbridge.EnvVar, "/paquet/manage/devzone")
	root, err := packageRoot()
	if err != nil || root != "/paquet" {
		t.Fatalf("packageRoot() = %q, %v", root, err)
	}
	t.Setenv(bashbridge.EnvVar, "")
	if _, err := packageRoot(); err == nil || !strings.Contains(err.Error(), "DEVZONE_BASH_ENTRY") {
		t.Fatalf("packageRoot() without entry: err = %v", err)
	}
}
