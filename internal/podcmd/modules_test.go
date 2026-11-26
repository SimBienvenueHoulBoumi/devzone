package podcmd

import (
	"io"
	"path/filepath"
	"strings"
	"testing"
)

// TestModulesRegistered checks that postgres and mysql are handled by the pod
// binary and that Ported lists them.
func TestModulesRegistered(t *testing.T) {
	for _, name := range []string{"postgres", "mysql", "gitlab", "test-gitlab"} {
		if _, ok := Registry.Lookup(name); !ok {
			t.Fatalf("%s not registered", name)
		}
	}
	joined := "," + strings.Join(Ported(), ",") + ","
	for _, name := range []string{",postgres,", ",mysql,", ",gitlab,", ",test-gitlab,"} {
		if !strings.Contains(joined, name) {
			t.Fatalf("Ported misses %s: %v", name, Ported())
		}
	}
}

// TestPostgresUnknownSubcommand checks the shell message and status of an
// unknown postgres subcommand, without delegating to the shell.
func TestPostgresUnknownSubcommand(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	var errOut strings.Builder
	if code := Run([]string{"postgres", "nope"}, io.Discard, &errOut); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	want := "devzone postgres: create <project> [--new-password] | list | psql [<project>] | delete <project> [--yes]\n"
	if errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", errOut.String(), want)
	}
}

// TestMysqlUnknownSubcommand checks the shell message and status of an unknown
// mysql subcommand.
func TestMysqlUnknownSubcommand(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	var errOut strings.Builder
	if code := Run([]string{"mysql", "nope"}, io.Discard, &errOut); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	want := "devzone : catalog mysql : create <project> [--new-password] | list | delete <project> [--yes] | volume [<name>] [--delete <name>] [--yes] | delete-data [--yes]\n"
	if errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", errOut.String(), want)
	}
}

// TestModuleStatusWithoutState checks that a module status before any
// installation is "disabled", as in the shell.
func TestModuleStatusWithoutState(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	for _, name := range []string{"postgres", "mysql"} {
		var out strings.Builder
		if code := Run([]string{name, "status"}, &out, io.Discard); code != 0 || out.String() != "disabled\n" {
			t.Fatalf("%s status: code %d, output %q", name, code, out.String())
		}
	}
}
