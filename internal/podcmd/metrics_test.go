package podcmd

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
)

// TestMetricsIsPorted checks that the launcher can route metrics to the Go
// binary, which decides between an Application and the existing shell path.
func TestMetricsIsPorted(t *testing.T) {
	if code := Run([]string{"handles", "metrics"}, io.Discard, io.Discard); code != 0 {
		t.Fatalf("handles metrics: code %d, want 0", code)
	}
}

// TestMetricsApplicationPath checks that an active Argo CD creates the
// dependency Application without reaching a real cluster or network.
func TestMetricsApplicationPath(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_POD_SCRIPT", filepath.Join(root, ".devcontainer", "devzone"))
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte("argocd=on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-argocd"}, fexec.Result{})
	r.On("kubectl", []string{"--context", "devzone", "apply", "-f", "-"}, fexec.Result{})
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	ctx := &cli.Context{Out: out, Err: errOut, Runner: r}
	if code := runMetrics(ctx); code != 0 {
		t.Fatalf("metrics: code %d, err = %q", code, errOut.String())
	}
	applied := ""
	for _, call := range r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm was called: %v", call.Args)
		}
		if call.Name == "kubectl" && strings.Join(call.Args, " ") == "--context devzone apply -f -" && call.Opts.Stdin != nil {
			data, err := io.ReadAll(call.Opts.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			applied = string(data)
		}
	}
	if !strings.Contains(applied, "name: devzone-metrics-server") || !strings.Contains(applied, "targetRevision: 3.12.1") {
		t.Fatalf("no pinned dependency Application: %q", applied)
	}
}
