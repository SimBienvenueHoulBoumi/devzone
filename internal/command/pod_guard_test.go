package command

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// TestRunInPodRefusesHostProgram checks that the pod variable stops the host
// program before a command or the bash delegate can do anything, and that the
// message gives the command to repair the masked image program.
func TestRunInPodRefusesHostProgram(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	var out, errOut bytes.Buffer
	if got := Run([]string{"help"}, &out, &errOut); got != 1 {
		t.Fatalf("exit status = %d, want 1", got)
	}
	if out.Len() != 0 {
		t.Fatalf("stdout = %q, want no command output", out.String())
	}
	if !strings.Contains(errOut.String(), "you are in the pod") ||
		!strings.Contains(errOut.String(), "npm uninstall -g devzone") {
		t.Fatalf("stderr = %q, want the pod and repair message", errOut.String())
	}
}

// TestRunOutsidePodKeepsDispatching checks that the guard leaves the host
// program unchanged when the pod variable is absent: the registered command
// still runs and reports its status.
func TestRunOutsidePodKeepsDispatching(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "")
	Registry.Register(cli.Command{Name: "pod-guard-probe", Run: func(ctx *cli.Context) int {
		io.WriteString(ctx.Out, "dispatched\n")
		return 7
	}})
	t.Cleanup(func() { Registry = newDefaultRegistry() })
	var out, errOut bytes.Buffer
	if got := Run([]string{"pod-guard-probe"}, &out, &errOut); got != 7 {
		t.Fatalf("exit status = %d, want 7", got)
	}
	if out.String() != "dispatched\n" || errOut.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", out.String(), errOut.String())
	}
}
