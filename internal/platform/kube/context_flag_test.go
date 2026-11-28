package kube

import (
	"context"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestNamespaceIsolateUsesCurrentContext checks that no context flag is added
// when kubeconfig does not declare the services context.
func TestNamespaceIsolateUsesCurrentContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte("kind-poste\n")})
	runner.On("kubectl", nil, fexec.Result{})
	k := Kube{Runner: runner}
	if err := k.NamespaceIsolate(context.Background(), "devzone-postgres", nil); err != nil {
		t.Fatal(err)
	}
	calls := runner.Calls()
	if len(calls) != 2 {
		t.Fatalf("calls = %+v", calls)
	}
	want := []string{"-n", "devzone-postgres", "apply", "-f", "-"}
	if strings.Join(calls[1].Args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args = %q, want %q", calls[1].Args, want)
	}
}

// TestNamespaceIsolateUsesDeclaredContext checks that the shared name override
// is prepended when kubeconfig declares that context.
func TestNamespaceIsolateUsesDeclaredContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte("kind-poste\nkind-lab\n")})
	runner.On("kubectl", nil, fexec.Result{})
	k := Kube{Runner: runner}
	if err := k.NamespaceIsolate(context.Background(), "devzone-postgres", nil); err != nil {
		t.Fatal(err)
	}
	calls := runner.Calls()
	if len(calls) != 2 {
		t.Fatalf("calls = %+v", calls)
	}
	want := []string{"--context", "kind-lab", "-n", "devzone-postgres", "apply", "-f", "-"}
	if strings.Join(calls[1].Args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args = %q, want %q", calls[1].Args, want)
	}
}
