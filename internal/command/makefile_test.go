//go:build !windows

package command

import (
	"bytes"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// repoRoot returns the repository root from this test file location.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

// runMake runs make with args in dir and returns stdout, stderr and exit error.
func runMake(t *testing.T, dir string, args ...string) (string, string, error) {
	t.Helper()
	cmd := exec.Command("make", args...)
	cmd.Dir = dir
	var out, errOut bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	err := cmd.Run()
	return out.String(), errOut.String(), err
}

// requireMake skips when make is not available, because the Makefile contract
// is only meaningful on hosts that provide make.
func requireMake(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("make"); err != nil {
		t.Skip("make not installed")
	}
}

func TestMakefileRemovedTargetsReportWorkspaceCommand(t *testing.T) {
	hostMode(t)
	requireMake(t)
	root := repoRoot(t)
	// Removed legacy targets must fail with a clear migration message so users
	// are directed to the supported devzone workspace commands.
	for _, target := range []string{"up", "shell", "stop", "down", "rebuild", "status"} {
		t.Run(target, func(t *testing.T) {
			_, errOut, err := runMake(t, root, target)
			if err == nil {
				t.Fatalf("make %s: expected non-zero exit", target)
			}
			if !strings.Contains(errOut, "devzone workspace") {
				t.Fatalf("make %s: stderr missing devzone workspace: %q", target, errOut)
			}
			if !strings.Contains(errOut, "removed") {
				t.Fatalf("make %s: stderr missing removed: %q", target, errOut)
			}
		})
	}
}

func TestMakefileHelpListsOnlySupportedTargets(t *testing.T) {
	requireMake(t)
	root := repoRoot(t)
	// help is the supported entry point; it must advertise remaining targets and
	// must not advertise removed legacy workstation targets.
	out, errOut, err := runMake(t, root, "help")
	if err != nil {
		t.Fatalf("make help: %v stderr=%q", err, errOut)
	}
	for _, want := range []string{"test-fonctionnel", "uninstall"} {
		if !strings.Contains(out, want) {
			t.Fatalf("make help: missing %q in %q", want, out)
		}
	}
	for _, removed := range []string{"up", "shell", "stop", "down", "rebuild", "status"} {
		if strings.Contains(out, removed) {
			t.Fatalf("make help: unexpected removed target %q in %q", removed, out)
		}
	}
}

func TestMakefileHelpDryRunSucceeds(t *testing.T) {
	requireMake(t)
	root := repoRoot(t)
	// Dry-run keeps help safe in CI and local checks; it must not fail because
	// of the default removal rule.
	_, errOut, err := runMake(t, root, "-n", "help")
	if err != nil {
		t.Fatalf("make -n help: %v stderr=%q", err, errOut)
	}
}
