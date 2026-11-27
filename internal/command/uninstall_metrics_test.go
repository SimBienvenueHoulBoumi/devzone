package command

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// metricsManifest is the release manifest of the pinned version of this test.
const metricsManifest = "https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml"

// withKubectl makes the host look like one with kubectl, for the test only.
func withKubectl(t *testing.T) {
	t.Helper()
	previous := lookPath
	lookPath = func(name string) (string, error) { return name, nil }
	t.Cleanup(func() { lookPath = previous })
}

// metricsRunner answers a host with two local clusters: kind-x, whose
// metrics-server devzone installed, and minikube, whose metrics-server it did not.
// A third context (other) is not a local cluster and is never asked.
func metricsRunner(t *testing.T, root string) *fake.Runner {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, ".devcontainer", "versions.env"), []byte("METRICS_SERVER_VERSION=v0.9.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := fake.New()
	registerHostProbe(t, runner, root)
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("kind-x\nminikube\nother\n")})
	for _, c := range []string{"kind-x", "minikube"} {
		runner.On("kubectl", kubectlArgs(c, "get", "--raw", "/readyz"), exec.Result{})
		runner.On("kubectl", kubectlArgs(c, "-n", "kube-system", "get", "deployment", "metrics-server", "-o", "jsonpath={.metadata.labels.devzone}"), exec.Result{})
	}
	runner.On("kubectl", kubectlArgs("kind-x", "-n", "kube-system", "get", "deployment", "metrics-server", "-o", "jsonpath={.metadata.labels.devzone}"),
		exec.Result{Stdout: []byte("installed")})
	runner.On("kubectl", kubectlArgs("kind-x", "delete", "-f", metricsManifest, "--ignore-not-found"), exec.Result{})
	return runner
}

// TestMetricsServerInstalledByDevzoneRemoved: the metrics-server devzone installed
// is deleted from its cluster; the one it did not install is only reported.
func TestMetricsServerInstalledByDevzoneRemoved(t *testing.T) {
	root := devzoneDir(t)
	withKubectl(t)
	runner := metricsRunner(t, root)
	code, out, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if !strings.Contains(out, "✔ metrics-server removed: kind-x") || strings.Contains(out, "removed: minikube") {
		t.Fatalf("output:\n%s", out)
	}
	if !strings.Contains(out, "metrics-server on minikube: not installed by devzone") {
		t.Fatalf("foreign metrics-server not reported:\n%s", out)
	}
	assertNoKubectlCall(t, runner, "other")
}

// TestMetricsServerDeleteFailureKeepsFiles: a failed deletion is reported with
// its cause, and the state files stay for a second run.
func TestMetricsServerDeleteFailureKeepsFiles(t *testing.T) {
	root := devzoneDir(t, "postgres=on")
	withKubectl(t)
	runner := metricsRunner(t, root)
	runner.OnError("kubectl", kubectlArgs("kind-x", "delete", "-f", metricsManifest, "--ignore-not-found"),
		exec.Result{Stderr: []byte("unauthorized")}, errors.New("exit 1"))
	code, _, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 1 || !strings.Contains(errOut, "✖ metrics-server kind-x: unauthorized") {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); err != nil {
		t.Fatalf("state file removed after a failed deletion: %v", err)
	}
}

// TestMetricsKubectlMissingReported: without kubectl on the host, no cluster is
// asked and the summary says so.
func TestMetricsKubectlMissingReported(t *testing.T) {
	root := devzoneDir(t)
	runner := fake.New()
	registerHostProbe(t, runner, root)
	code, out, errOut := runUninstall(t, runner, root, []string{"--yes"}, "")
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut)
	}
	if !strings.Contains(out, "metrics-server: kubectl not on host, host clusters not checked") {
		t.Fatalf("no kubectl notice:\n%s", out)
	}
	for _, c := range runner.Calls() {
		// The Kubernetes part reads the kubeconfig contexts; no cluster is asked
		if c.Name == "kubectl" && !(len(c.Args) > 0 && c.Args[0] == "config") {
			t.Fatalf("cluster asked without kubectl on the host: %v", c.Args)
		}
	}
}

// assertNoKubectlCall fails when a kubectl call selects the given context.
func assertNoKubectlCall(t *testing.T, runner *fake.Runner, kubeCtx string) {
	t.Helper()
	for _, c := range runner.Calls() {
		if c.Name == "kubectl" && len(c.Args) > 1 && c.Args[0] == "--context" && c.Args[1] == kubeCtx {
			t.Fatalf("kubectl called on %s: %v", kubeCtx, c.Args)
		}
	}
}

// TestKubectlArgsCarryTimeout checks that every host cluster call carries the
// 5 second request timeout of the shell uninstaller.
func TestKubectlArgsCarryTimeout(t *testing.T) {
	args := kubectlArgs("kind-x", "get")
	if len(args) < 3 || args[0] != "--context" || args[1] != "kind-x" || args[2] != "--request-timeout=5s" {
		t.Fatalf("args = %v", args)
	}
}
