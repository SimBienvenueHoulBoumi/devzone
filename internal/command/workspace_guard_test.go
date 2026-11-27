package command

import (
	"bytes"
	"io"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// TestAgentsGuardCommandRunsInGo checks that the internal command is served by
// the Go handler and does not reach the shell entry point.
func TestAgentsGuardCommandRunsInGo(t *testing.T) {
	previous := commandAgentsGuard
	t.Cleanup(func() { commandAgentsGuard = previous })
	calls := 0
	commandAgentsGuard = func(io.Writer) { calls++ }
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"agents-guard"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, want 0", code)
	}
	if calls != 1 || errOut.Len() != 0 {
		t.Fatalf("guard calls = %d, stderr = %q", calls, errOut.String())
	}
}

// TestAgentsGuardCommandUsesContextOutput checks that the guard message goes to
// the output of the caller, as the shell function wrote to its standard output.
func TestAgentsGuardCommandUsesContextOutput(t *testing.T) {
	previous := commandAgentsGuard
	t.Cleanup(func() { commandAgentsGuard = previous })
	commandAgentsGuard = func(out io.Writer) {
		_, _ = io.WriteString(out, "✔ repowarden guard active\n")
	}
	var out bytes.Buffer
	ctx := &cli.Context{Args: []string{"agents-guard"}, Out: &out, Err: &bytes.Buffer{}}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, want 0", code)
	}
	if out.String() != "✔ repowarden guard active\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}
