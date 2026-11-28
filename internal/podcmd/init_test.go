package podcmd

import (
	"io"
	"os"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestInitFirstRun covers the first startup: installation, safe.directory and
// the prompt block, with the real module application on a disabled state.
func TestInitFirstRun(t *testing.T) {
	f := newInitFixture(t)
	if code := f.run(); code != 0 {
		t.Fatalf("code %d, want 0; journal:\n%s", code, f.out.String())
	}
	for _, line := range []string{
		"safe.directory " + safeDirectory + " added",
		"repowarden " + f.pinned + " installed",
		"repowarden global hooks installed",
		"modules applied",
		"prompt block added to " + f.bashrc,
		"done",
	} {
		if !f.hasLogLine(line) {
			t.Errorf("journal misses %q:\n%s", line, f.out.String())
		}
	}
	if !f.called("git", "config", "--global", "--add", "safe.directory", safeDirectory) {
		t.Errorf("git add missing: %v", f.runner.Calls())
	}
	if !f.called("npm", "install", "-g", "repowarden@"+f.pinned) {
		t.Errorf("npm install missing: %v", f.runner.Calls())
	}
	if !f.called("repowarden", "install", "--global", "--lang", "fr") {
		t.Errorf("repowarden hooks missing: %v", f.runner.Calls())
	}
	if f.applyRuns != 1 {
		t.Errorf("module application ran %d times, want 1", f.applyRuns)
	}
	content := f.read(f.bashrc)
	if !strings.Contains(content, promptBlock) || strings.Count(content, promptStart) != 1 {
		t.Errorf("prompt block = %q", content)
	}
}

// TestInitSecondRun covers a second startup: no second prompt block and no new
// npm installation when repowarden already reports the pinned version.
func TestInitSecondRun(t *testing.T) {
	f := newInitFixture(t)
	if code := f.run(); code != 0 {
		t.Fatalf("first code %d", code)
	}
	f.out.Reset()
	f.runner.On("git", []string{"config", "--global", "--get-all", "safe.directory"},
		exec.Result{Stdout: []byte(safeDirectory + "\n")})
	f.runner.On("repowarden", []string{"--version"},
		exec.Result{Stdout: []byte(f.pinned + "\n")})
	before := len(f.runner.Calls())
	if code := f.run(); code != 0 {
		t.Fatalf("second code %d; journal:\n%s", code, f.out.String())
	}
	for _, line := range []string{
		"safe.directory " + safeDirectory + " already set",
		"repowarden " + f.pinned + " already installed",
		"modules applied",
		"prompt block already present",
		"done",
	} {
		if !f.hasLogLine(line) {
			t.Errorf("journal misses %q:\n%s", line, f.out.String())
		}
	}
	for _, call := range f.runner.Calls()[before:] {
		if call.Name == "npm" {
			t.Errorf("npm ran again: %v", call)
		}
	}
	if got := strings.Count(f.read(f.bashrc), promptStart); got != 1 {
		t.Errorf("prompt markers = %d, want 1", got)
	}
}

// TestInitMissingVersionsFile covers the missing versions file: the message is
// logged and the remaining steps still run.
func TestInitMissingVersionsFile(t *testing.T) {
	f := newInitFixture(t)
	if err := os.Remove(f.versions); err != nil {
		t.Fatal(err)
	}
	if code := f.run(); code != 0 {
		t.Fatalf("code %d, want 0; journal:\n%s", code, f.out.String())
	}
	for _, line := range []string{
		"repowarden: " + f.versions + " missing",
		"modules applied",
		"prompt block added to " + f.bashrc,
		"done",
	} {
		if !f.hasLogLine(line) {
			t.Errorf("journal misses %q:\n%s", line, f.out.String())
		}
	}
	if f.called("npm", "install", "-g", "repowarden@"+f.pinned) {
		t.Errorf("npm ran without a versions file: %v", f.runner.Calls())
	}
}

// TestInitApplyFailureContinues covers a failing module step: later steps run,
// "done" is written and the command reports the failure in its exit status.
func TestInitApplyFailureContinues(t *testing.T) {
	f := newInitFixture(t)
	f.applyCode = 1
	if code := f.run(); code != 1 {
		t.Fatalf("code %d, want 1; journal:\n%s", code, f.out.String())
	}
	for _, line := range []string{
		"safe.directory " + safeDirectory + " added",
		"repowarden global hooks installed",
		"modules incomplete",
		"prompt block added to " + f.bashrc,
		"done",
	} {
		if !f.hasLogLine(line) {
			t.Errorf("journal misses %q:\n%s", line, f.out.String())
		}
	}
	if !strings.Contains(f.read(f.bashrc), promptBlock) {
		t.Error("prompt block missing after the module failure")
	}
}

// TestInitIsRegistered checks that the launcher routes the init command to the
// Go pod binary instead of delegating it to the shell entry point.
func TestInitIsRegistered(t *testing.T) {
	if _, ok := Registry.Lookup("init"); !ok {
		t.Fatal("init not registered")
	}
	if code := Run([]string{"handles", "init"}, io.Discard, io.Discard); code != 0 {
		t.Fatalf("handles init: code %d", code)
	}
}
