package mysql

import (
	"context"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestKubectlArgsUsesCurrentContext checks that MySQL leaves kubectl on the
// current context when kubeconfig does not declare the services context.
func TestKubectlArgsUsesCurrentContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	runner := fake.New()
	runner.On("kubectl", nil, fexec.Result{Stdout: []byte("kind-poste\n")})
	e := &env{ctx: context.Background(), opts: Options{Runner: runner}}
	got := e.kubectlArgs(ns, "get", "pods")
	want := []string{"-n", ns, "get", "pods"}
	if len(got) != len(want) {
		t.Fatalf("args = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("args = %q, want %q", got, want)
		}
	}
}

// TestKubectlArgsUsesDeclaredContext checks that MySQL uses the configured
// services context name only when kubeconfig declares it.
func TestKubectlArgsUsesDeclaredContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	runner := fake.New()
	runner.On("kubectl", nil, fexec.Result{Stdout: []byte("kind-poste\nkind-lab\n")})
	e := &env{ctx: context.Background(), opts: Options{Runner: runner}}
	got := e.kubectlArgs(ns, "get", "pods")
	want := []string{"--context", "kind-lab", "-n", ns, "get", "pods"}
	if len(got) != len(want) {
		t.Fatalf("args = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("args = %q, want %q", got, want)
		}
	}
}
