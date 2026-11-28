package command

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// argoCDRequiredMessage is the exact two-line message written when Argo CD is
// required but not running, shared by start and update.
const argoCDRequiredMessage = "devzone : workspace : Argo CD is required but not running,\nplease run: devzone enable argocd\n"

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
	stubStartEffects(t)

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

// TestWorkspaceStartEnableFailureStops replaces the former "warning" behaviour:
// a failed Argo CD enable stops the start with code 1 and the Argo CD message,
// without deploying anything.
func TestWorkspaceStartEnableFailureStops(t *testing.T) {
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
	stubStartEffects(t)

	var out, errOut bytes.Buffer
	if code := Run([]string{"workspace", "start"}, &out, &errOut); code != 1 {
		t.Fatalf("status = %d, want 1 (err %q)", code, errOut.String())
	}
	if errOut.String() != argoCDRequiredMessage {
		t.Fatalf("err = %q, want the Argo CD required message", errOut.String())
	}
	if out.Len() != 0 {
		t.Fatalf("out = %q, want nothing", out.String())
	}
}

// stubStartEffects installs no-op stand-ins for the start effects that a
// routing test does not exercise, and restores them afterwards.
func stubStartEffects(t *testing.T) {
	t.Helper()
	oldReconcile, oldWait, oldGuard, oldPorts := commandStartReconcile, commandStartWait, commandStartGuard, commandStartPorts
	t.Cleanup(func() {
		commandStartReconcile, commandStartWait, commandStartGuard, commandStartPorts = oldReconcile, oldWait, oldGuard, oldPorts
	})
	commandStartReconcile = func(_ *cli.Context) int { return 0 }
	commandStartWait = func(_ workspace.Runner, _ string, _ io.Writer, _ io.Writer) int { return 0 }
	commandStartGuard = func(_ workspace.Runner, _ io.Writer) {}
	commandStartPorts = func(_ io.Writer, _ io.Writer) int { return 0 }
}

// startRun runs "workspace start" with a programmable runner and a modules
// state file, without reaching a cluster or the network.
func startRun(t *testing.T, modules string, r *fake.Runner) (*bytes.Buffer, *bytes.Buffer, int) {
	t.Helper()
	t.Chdir(t.TempDir())
	writeModules(t, modules)
	root, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	ctx := &cli.Context{Args: []string{"start"}, Out: out, Err: errOut, Runner: r}
	code := workspaceCommand(ctx)
	return out, errOut, code
}

// noHelm asserts that the fake runner never ran a helm command.
func noHelm(t *testing.T, r *fake.Runner) {
	t.Helper()
	for _, call := range r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm was called although Argo CD drives the deploy: %v", call.Args)
		}
	}
}

// TestWorkspaceStartArgoCDAbsentStops checks that an Argo CD wanted but not
// running stops the start with code 1 and the Argo CD message, without helm.
func TestWorkspaceStartArgoCDAbsentStops(t *testing.T) {
	hostMode(t)
	fakeClusterReady(t)
	r := fake.New()
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		fexec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-argocd"},
		fexec.Result{Code: 1})
	commandStartDeploy = startWorkspaceDeploy
	t.Cleanup(func() { commandStartDeploy = startWorkspaceDeploy })
	commandStartEnableArgoCD = func(_ *cli.Context) int { return 0 }
	t.Cleanup(func() {
		commandStartEnableArgoCD = func(ctx *cli.Context) int {
			return commandServices([]string{"services", "enable", "argocd"}, ctx.Out, ctx.Err)
		}
	})
	stubStartEffects(t)

	_, errOut, code := startRun(t, "kubernetes=on\nargocd=on\n", r)
	if code != 1 {
		t.Fatalf("status = %d, want 1 (err %q)", code, errOut.String())
	}
	if errOut.String() != argoCDRequiredMessage {
		t.Fatalf("err = %q, want the Argo CD required message", errOut.String())
	}
	noHelm(t, r)
}

// TestWorkspaceStartArgoCDEnableFailureStops checks that a failed Argo CD
// enable stops the start with code 1 and the Argo CD message, without deploying.
func TestWorkspaceStartArgoCDEnableFailureStops(t *testing.T) {
	hostMode(t)
	fakeClusterReady(t)
	r := fake.New()
	deployCalls := 0
	commandStartDeploy = func(_ *cli.Context, _ string, _ string, _ bool) int {
		deployCalls++
		return 0
	}
	t.Cleanup(func() { commandStartDeploy = startWorkspaceDeploy })
	commandStartEnableArgoCD = func(_ *cli.Context) int { return 1 }
	t.Cleanup(func() {
		commandStartEnableArgoCD = func(ctx *cli.Context) int {
			return commandServices([]string{"services", "enable", "argocd"}, ctx.Out, ctx.Err)
		}
	})
	stubStartEffects(t)

	_, errOut, code := startRun(t, "kubernetes=on\nargocd=on\n", r)
	if code != 1 {
		t.Fatalf("status = %d, want 1 (err %q)", code, errOut.String())
	}
	if errOut.String() != argoCDRequiredMessage {
		t.Fatalf("err = %q, want the Argo CD required message", errOut.String())
	}
	if deployCalls != 0 {
		t.Fatalf("deploy calls = %d, want 0: Argo CD enable failed", deployCalls)
	}
	noHelm(t, r)
}

// TestWorkspaceStartArgoCDPresentDeploys checks that Argo CD wanted and enabled
// deploys through the Application with code 0 and no helm fallback.
func TestWorkspaceStartArgoCDPresentDeploys(t *testing.T) {
	hostMode(t)
	fakeClusterReady(t)
	r := fake.New()
	deployCalls := 0
	commandStartDeploy = func(_ *cli.Context, _ string, _ string, _ bool) int {
		deployCalls++
		return 0
	}
	t.Cleanup(func() { commandStartDeploy = startWorkspaceDeploy })
	commandStartEnableArgoCD = func(_ *cli.Context) int { return 0 }
	t.Cleanup(func() {
		commandStartEnableArgoCD = func(ctx *cli.Context) int {
			return commandServices([]string{"services", "enable", "argocd"}, ctx.Out, ctx.Err)
		}
	})
	stubStartEffects(t)

	out, errOut, code := startRun(t, "kubernetes=on\nargocd=on\n", r)
	if code != 0 {
		t.Fatalf("status = %d, want 0 (err %q)", code, errOut.String())
	}
	if deployCalls != 1 {
		t.Fatalf("deploy calls = %d, want 1", deployCalls)
	}
	if errOut.Len() != 0 {
		t.Fatalf("err = %q, want nothing", errOut.String())
	}
	if strings.Contains(out.String(), "helm") {
		t.Fatalf("out = %q, want no helm mention", out.String())
	}
	noHelm(t, r)
}
