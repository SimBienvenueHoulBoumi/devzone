package command

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// statusRunner answers the kubectl calls of "workspace status" in memory: the
// pod is listed, no context declared, and no program of the PATH runs.
type statusRunner struct {
	calls []string
}

// Kubectl answers the context listing and the pod listing, like the fake
// kubectl of the former shell tests, without any PATH entry.
func (s *statusRunner) Kubectl(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	s.calls = append(s.calls, strings.Join(args, " "))
	if strings.Contains(strings.Join(args, " "), "get pods") {
		_, _ = io.WriteString(stdout, "devzone-workspace-0  1/1  Running\n")
	}
	return 0, nil
}

// Helm answers nothing.
func (s *statusRunner) Helm(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	return 0, nil
}

func TestWorkspaceStatusRunsInGo(t *testing.T) {
	r := &statusRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "status"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(out.String(), "devzone-workspace-0") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want the pod listed by Go, not a delegation", out.String())
	}
}

func TestWorkspaceStatusWithWordsIsIgnored(t *testing.T) {
	r := &statusRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "status", "extra"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(out.String(), "devzone-workspace-0") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want the pod listed by Go, not a delegation", out.String())
	}
}

func TestWorkspaceAlonePrintsHelp(t *testing.T) {
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(out.String(), "devzone workspace start|stop|status") {
		t.Fatalf("stdout = %q, want the Go help", out.String())
	}
}

func TestWorkspaceUnknownIsRefused(t *testing.T) {
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "nope", "x"}, &out, &errOut); got != 1 {
		t.Fatalf("exit status = %d, want 1", got)
	}
	want := "✖ unknown subcommand: nope (devzone workspace start|stop|status|shell|ports|services|argocd|update)\n"
	if errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", errOut.String(), want)
	}
}

// TestWorkspaceStartEnablesWatcher checks that a successful cluster start
// triggers the single automatic-start function and that a failed one does not.
func TestWorkspaceStartEnablesWatcher(t *testing.T) {
	fakeClusterReady(t)
	t.Setenv("DEVZONE_ROOT", devzoneRootForAutoStart(t))
	calls := 0
	previous := commandEnsureAutoStart
	commandEnsureAutoStart = func(out, _ io.Writer) {
		calls++
		fmt.Fprintln(out, "✔ port watcher: automatic start enabled")
	}
	t.Cleanup(func() { commandEnsureAutoStart = previous })
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
	if got := Run([]string{"workspace", "start", "--image", "x:1"}, &out, &errOut); got != 0 {
		t.Fatalf("status = %d, err = %q", got, errOut.String())
	}
	want := "✔ port watcher: automatic start enabled\n"
	if out.String() != want || calls != 1 {
		t.Fatalf("stdout = %q, enable calls = %d, want %q and 1", out.String(), calls, want)
	}
	commandStartDeploy = func(_ *cli.Context, _ string, _ string, _ bool) int { return 1 }
	var out2, errOut2 bytes.Buffer
	if got := Run([]string{"workspace", "start"}, &out2, &errOut2); got != 1 {
		t.Fatalf("failed start status = %d, want 1", got)
	}
	if calls != 1 || strings.Contains(out2.String(), "automatic start") {
		t.Fatalf("failed start enabled the watcher: calls = %d, out = %q", calls, out2.String())
	}
}
