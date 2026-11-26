package kube

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// funcRunner adapts a function to the Runner interface for ordered scenarios.
type funcRunner func(context.Context, string, []string, exec.Opts) (exec.Result, error)

// Run implements the Runner interface.
func (f funcRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	return f(ctx, name, args, opts)
}

// TestClusterPrepareRetriesKind checks that a failed creation is retried and
// that the working context is restored, as kind_create_keep_context did.
func TestClusterPrepareRetriesKind(t *testing.T) {
	t.Setenv("DEVZONE_INSTANCE", "devzone")
	var calls []string
	creates := 0
	runner := funcRunner(func(_ context.Context, name string, args []string, _ exec.Opts) (exec.Result, error) {
		line := name + " " + strings.Join(args, " ")
		calls = append(calls, line)
		switch line {
		case "kubectl config current-context":
			return exec.Result{Stdout: []byte("host-context\n")}, nil
		case "kind get clusters":
			return exec.Result{}, nil
		case "kind create cluster --name devzone --wait 120s":
			creates++
			if creates == 1 {
				return exec.Result{Code: 1}, nil
			}
			return exec.Result{}, nil
		case "kubectl config view -o {.contexts[?(@.name==\"kind-devzone\")].context.cluster}":
			return exec.Result{Stdout: []byte("kind-devzone-cluster\n")}, nil
		case "kubectl config view -o {.contexts[?(@.name==\"kind-devzone\")].context.user}":
			return exec.Result{Stdout: []byte("kind-devzone-user\n")}, nil
		}
		return exec.Result{}, nil
	})
	var out, errOut bytes.Buffer
	k := Kube{Runner: runner}
	if err := k.ClusterPrepare(context.Background(), "kind-devzone", &out, &errOut); err != nil {
		t.Fatalf("ClusterPrepare: %v, err = %q", err, errOut.String())
	}
	if creates != 2 || !strings.Contains(out.String(), "Retrying the kind cluster creation") {
		t.Fatalf("creates = %d, out = %q", creates, out.String())
	}
	if !hasCallLine(calls, "kind delete cluster --name devzone") ||
		!hasCallLine(calls, "kubectl config use-context host-context") {
		t.Fatalf("calls = %v", calls)
	}
}

// hasCallLine reports whether one exact command was run.
func hasCallLine(calls []string, want string) bool {
	for _, call := range calls {
		if call == want {
			return true
		}
	}
	return false
}

// TestMetricsVersionReadsInstalledFile checks that the pinned version comes
// from versions.env of the installed code when that file exists.
func TestMetricsVersionReadsInstalledFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "devzone")
	if err := os.WriteFile(filepath.Join(dir, "versions.env"), []byte("METRICS_SERVER_VERSION=v1.2.3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_POD_SCRIPT", path)
	if got := metricsVersion(); got != "v1.2.3" {
		t.Fatalf("metricsVersion = %q, want v1.2.3", got)
	}
	if got := metricsManifest(); !strings.Contains(got, "v1.2.3/components.yaml") {
		t.Fatalf("manifest = %q", got)
	}
}
