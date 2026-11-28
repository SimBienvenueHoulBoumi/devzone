package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// heldCase runs metricsHeldByArgoCD with an active module and a kubeconfig
// listing the given contexts, then returns the kubectl arguments of the
// namespace probe.
func heldCase(t *testing.T, contexts string) []string {
	t.Helper()
	root := t.TempDir()
	state := filepath.Join(root, ".devzone.modules")
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", state)
	if err := os.WriteFile(state, []byte("argocd=on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte(contexts)})
	r.On("kubectl", nil, fexec.Result{})
	if !metricsHeldByArgoCD(&cli.Context{Runner: r}) {
		t.Fatal("metricsHeldByArgoCD = false, want true")
	}
	calls := r.Calls()
	if len(calls) != 2 {
		t.Fatalf("calls = %+v, want the context list then the namespace probe", calls)
	}
	return calls[1].Args
}

// TestMetricsHeldWithoutContextFlag checks that the namespace probe keeps the
// current context when kubeconfig does not declare the services context.
func TestMetricsHeldWithoutContextFlag(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	args := heldCase(t, "kind-poste\n")
	want := []string{"get", "namespace", "devzone-argocd"}
	if strings.Join(args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args = %q, want %q", args, want)
	}
}

// TestMetricsHeldWithContextFlag checks that the DEVZONE_CONTEXT override is
// prepended when kubeconfig declares that context.
func TestMetricsHeldWithContextFlag(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	args := heldCase(t, "kind-poste\nkind-lab\n")
	want := []string{"--context", "kind-lab", "get", "namespace", "devzone-argocd"}
	if strings.Join(args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args = %q, want %q", args, want)
	}
}
