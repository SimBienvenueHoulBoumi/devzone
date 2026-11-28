package command

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestArgoCDHoldsWorkspaceUsesCurrentContext checks that a workstation without
// the services context targets the current context instead of a hard-coded one.
func TestArgoCDHoldsWorkspaceUsesCurrentContext(t *testing.T) {
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		fexec.Result{Stdout: []byte("kind-poste\n")})
	runner.On("kubectl", []string{"get", "namespace", "devzone-argocd"}, fexec.Result{})
	state := t.TempDir() + "/.devzone.modules"
	if !argoCDHoldsWorkspace(runner, state) {
		t.Fatalf("Argo CD was not found at the current context: %v", runner.Calls())
	}
	for _, call := range runner.Calls() {
		if call.Name != "kubectl" {
			continue
		}
		line := strings.Join(call.Args, " ")
		if strings.Contains(line, "--context devzone") {
			t.Errorf("services context was forced on a workstation without it: %q", line)
		}
	}
}

// TestArgoCDHoldsWorkspaceKeepsDeclaredContext checks that the flag is kept
// when kubeconfig really declares the services context.
func TestArgoCDHoldsWorkspaceKeepsDeclaredContext(t *testing.T) {
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		fexec.Result{Stdout: []byte("kind-poste\ndevzone\n")})
	runner.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-argocd"},
		fexec.Result{})
	if !argoCDHoldsWorkspace(runner, t.TempDir()+"/.devzone.modules") {
		t.Fatalf("Argo CD was not found with the declared context: %v", runner.Calls())
	}
}
