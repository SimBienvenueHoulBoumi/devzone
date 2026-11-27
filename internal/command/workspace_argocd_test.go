package command

import (
	"bytes"
	"context"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// stubArgoCDReconcile replaces the collaborators of reconciliation for one
// test: no kubectl, no package lookup and no Argo CD library call is real.
func stubArgoCDReconcile(t *testing.T, installed, holds bool, status int) *[]string {
	t.Helper()
	previousRun := workstationArgoCDRun
	previousInstalled, previousHolds := commandArgoCDInstalled, commandArgoCDHoldsCharts
	t.Cleanup(func() {
		workstationArgoCDRun = previousRun
		commandArgoCDInstalled, commandArgoCDHoldsCharts = previousInstalled, previousHolds
	})
	commandArgoCDInstalled = func(workspace.Runner) bool { return installed }
	commandArgoCDHoldsCharts = func(workspace.Runner, string) bool { return holds }
	calls := &[]string{}
	workstationArgoCDRun = func(_ context.Context, args []string, _, _ io.Writer, _ argocd.Options) int {
		*calls = append(*calls, strings.Join(args, " "))
		return status
	}
	return calls
}

// TestArgoCDReconcileFollowsTheState checks that the workstation reconciliation
// reaches the shared library only when Argo CD is installed, and that services
// are reconciled only when the charts are held by it.
func TestArgoCDReconcileFollowsTheState(t *testing.T) {
	for _, tc := range []struct {
		name      string
		installed bool
		holds     bool
		status    int
		want      string
		code      int
	}{
		{"not installed", false, false, 0, "", 0},
		{"installed without charts", true, false, 0, "apply", 0},
		{"charts held", true, true, 0, "apply,services-reconcile", 0},
		{"refusal stops before services", true, true, 2, "apply", 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := stubArgoCDReconcile(t, tc.installed, tc.holds, tc.status)
			ctx := &cli.Context{Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
			if code := argoCDReconcileCommand(ctx); code != tc.code {
				t.Fatalf("status = %d, want %d", code, tc.code)
			}
			if got := strings.Join(*calls, ","); got != tc.want {
				t.Fatalf("library calls = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestWorkspaceArgoCDReconcileIsRouted checks that the command issued by the
// workstation entry point runs in Go instead of falling back to the shell.
func TestWorkspaceArgoCDReconcileIsRouted(t *testing.T) {
	calls := stubArgoCDReconcile(t, true, false, 0)
	ctx := &cli.Context{Args: []string{"argocd", "reconcile"}, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d", code)
	}
	if got := strings.Join(*calls, ","); got != "apply" {
		t.Fatalf("library calls = %q, want %q", got, "apply")
	}
}
