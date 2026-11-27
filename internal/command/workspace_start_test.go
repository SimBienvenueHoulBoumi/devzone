package command

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// TestWorkspaceStartWithoutServiceManagerSucceeds keeps a successful cluster
// start on a host without a service manager: Go installs nothing and says
// nothing, without changing the status of the start.
func TestWorkspaceStartWithoutServiceManagerSucceeds(t *testing.T) {
	h := newAutoStartHarness(t)
	h.available = false
	fakeClusterReady(t)
	t.Setenv("DEVZONE_ROOT", devzoneRootForAutoStart(t))
	commandStartDeploy = func(_ *cli.Context, _ string, _ string, _ bool) int { return 0 }
	t.Cleanup(func() { commandStartDeploy = startWorkspaceDeploy })
	commandStartEnableArgoCD = func(_ *cli.Context) int { return 0 }
	t.Cleanup(func() {
		commandStartEnableArgoCD = func(ctx *cli.Context) int {
			return commandServices([]string{"services", "enable", "argocd"}, ctx.Out, ctx.Err)
		}
	})
	commandStartReconcile = func(_ *cli.Context) int { return 0 }
	t.Cleanup(func() { commandStartReconcile = argoCDReconcileCommand })
	commandStartWait = func(_ workspace.Runner, _ string, _ io.Writer, _ io.Writer) int { return 0 }
	t.Cleanup(func() {
		commandStartWait = func(r workspace.Runner, image string, out, errOut io.Writer) int {
			return runPodWaitWith(r, image, out, errOut)
		}
	})
	commandStartGuard = func(_ workspace.Runner, _ io.Writer) {}
	t.Cleanup(func() { commandStartGuard = func(r workspace.Runner, out io.Writer) { workspace.AgentsGuard(r, out) } })
	commandStartPorts = func(_ io.Writer, _ io.Writer) int { return 0 }
	t.Cleanup(func() { commandStartPorts = func(out, errOut io.Writer) int { return commandPortsStart(out, errOut) } })

	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if h.enableCalls != 0 {
		t.Fatalf("enable calls = %d, want 0: no service manager on this host", h.enableCalls)
	}
	if errOut.Len() != 0 {
		t.Fatalf("err = %q, want nothing", errOut.String())
	}
}

// TestWorkspaceStartEnableFailureIsWarning keeps a successful cluster start
// successful when the single automatic-start function fails afterwards: the
// reason is written on errOut, but the status stays 0.
func TestWorkspaceStartEnableFailureIsWarning(t *testing.T) {
	newAutoStartHarness(t)
	fakeClusterReady(t)
	t.Setenv("DEVZONE_ROOT", devzoneRootForAutoStart(t))
	commandStartDeploy = func(_ *cli.Context, _ string, _ string, _ bool) int { return 0 }
	t.Cleanup(func() { commandStartDeploy = startWorkspaceDeploy })
	commandStartEnableArgoCD = func(_ *cli.Context) int { return 1 }
	t.Cleanup(func() {
		commandStartEnableArgoCD = func(ctx *cli.Context) int {
			return commandServices([]string{"services", "enable", "argocd"}, ctx.Out, ctx.Err)
		}
	})
	commandStartReconcile = func(_ *cli.Context) int { return 0 }
	t.Cleanup(func() { commandStartReconcile = argoCDReconcileCommand })
	commandStartWait = func(_ workspace.Runner, _ string, _ io.Writer, _ io.Writer) int { return 0 }
	t.Cleanup(func() {
		commandStartWait = func(r workspace.Runner, image string, out, errOut io.Writer) int {
			return runPodWaitWith(r, image, out, errOut)
		}
	})
	commandStartGuard = func(_ workspace.Runner, _ io.Writer) {}
	t.Cleanup(func() { commandStartGuard = func(r workspace.Runner, out io.Writer) { workspace.AgentsGuard(r, out) } })
	commandStartPorts = func(_ io.Writer, _ io.Writer) int { return 0 }
	t.Cleanup(func() { commandStartPorts = func(out, errOut io.Writer) int { return commandPortsStart(out, errOut) } })

	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 0 {
		t.Fatalf("status = %d, want 0 (err %q)", code, errOut.String())
	}
	if !strings.Contains(errOut.String(), "⚠ Argo CD not installed: the workspace is deployed with helm directly") {
		t.Fatalf("err = %q, want the Argo CD fallback warning", errOut.String())
	}
}
