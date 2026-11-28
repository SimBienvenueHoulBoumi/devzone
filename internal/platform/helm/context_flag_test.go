package helm

import (
	"bytes"
	"context"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// hasArg reports whether args holds want.
func hasArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

// install runs Install on the repository charts with a fake runner and returns
// the recorded calls, so a test can inspect the context flags.
func install(t *testing.T, runner *fake.Runner) []fake.Call {
	t.Helper()
	var errOut bytes.Buffer
	if _, code := Install(context.Background(), runner, "../../../.devcontainer", "postgres", "devzone-postgres", nil, &errOut); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, errOut.String())
	}
	return runner.Calls()
}

// TestInstallUsesCurrentContext checks that no kube context flag is prepended
// when kubeconfig does not declare the services context.
func TestInstallUsesCurrentContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte("kind-poste\n")})
	runner.On("kubectl", nil, fexec.Result{})
	runner.On("helm", nil, fexec.Result{})
	for _, call := range install(t, runner) {
		if call.Name == "helm" && hasArg(call.Args, "upgrade") {
			if hasArg(call.Args, "--kube-context") {
				t.Fatalf("upgrade args = %q, want no context flag", call.Args)
			}
			return
		}
	}
	t.Fatal("no helm upgrade call recorded")
}

// TestInstallUsesDeclaredContext checks that the shared name override is used
// when kubeconfig declares that context.
func TestInstallUsesDeclaredContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte("kind-poste\nkind-lab\n")})
	runner.On("kubectl", nil, fexec.Result{})
	runner.On("helm", nil, fexec.Result{})
	for _, call := range install(t, runner) {
		if call.Name == "helm" && hasArg(call.Args, "upgrade") {
			if len(call.Args) < 2 || call.Args[0] != "--kube-context" || call.Args[1] != "kind-lab" {
				t.Fatalf("upgrade args = %q, want --kube-context kind-lab", call.Args)
			}
			return
		}
	}
	t.Fatal("no helm upgrade call recorded")
}
