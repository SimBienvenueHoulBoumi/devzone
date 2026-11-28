package argocd

import (
	"context"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestKubectlArgsUsesCurrentContext checks that the module prepends no context
// flag when kubeconfig does not declare the services context.
func TestKubectlArgsUsesCurrentContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	runner := fake.New()
	runner.On("kubectl", nil, fexec.Result{Stdout: []byte("kind-poste\n")})
	m := &module{ctx: context.Background(), runner: runner}
	args := m.kubectlArgs("get", "pods")
	if len(args) != 2 || args[0] != "get" || args[1] != "pods" {
		t.Fatalf("args = %q, want the call unchanged", args)
	}
}

// TestKubectlArgsUsesDeclaredContext checks that the shared name override is
// used when kubeconfig declares that context.
func TestKubectlArgsUsesDeclaredContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	runner := fake.New()
	runner.On("kubectl", nil, fexec.Result{Stdout: []byte("kind-poste\nkind-lab\n")})
	m := &module{ctx: context.Background(), runner: runner}
	want := []string{"--context", "kind-lab", "get", "pods"}
	got := m.kubectlArgs("get", "pods")
	if len(got) != len(want) {
		t.Fatalf("args = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("args = %q, want %q", got, want)
		}
	}
}
