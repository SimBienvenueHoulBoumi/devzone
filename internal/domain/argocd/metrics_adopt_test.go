package argocd

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// metricsGet is the read of the legacy mark on the kube-system deployment.
var metricsGet = []string{"--context", "devzone", "-n", "kube-system", "get", "deployment", "metrics-server",
	"-o", "jsonpath={.metadata.labels.devzone}"}

// absentMetrics makes the deployment read answer NotFound, as on a fresh cluster.
func absentMetrics(f *modFixture) {
	f.r.On("kubectl", metricsGet, fexec.Result{Code: 1, Stderr: []byte(`Error from server (NotFound): deployments.apps "metrics-server" not found`)})
}

// hasKubectlApply reports whether the Application was applied.
func hasKubectlApply(f *modFixture) bool {
	return hasCall(f.r.Calls(), "kubectl", "--context", "devzone", "apply", "-f", "-")
}

// TestMetricsAdoptAbsent checks that a fresh cluster gets the Application
// without any deletion.
func TestMetricsAdoptAbsent(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	absentMetrics(f)
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	if !hasKubectlApply(f) {
		t.Fatal("no Application applied on a fresh cluster")
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && len(call.Args) > 0 && call.Args[len(call.Args)-2] == "delete" {
			t.Fatalf("a deletion ran on a fresh cluster: %v", call.Args)
		}
	}
}

// TestMetricsAdoptLegacyDevzone checks that the copy marked by devzone is
// replaced by the chart: the two legacy objects are deleted, then the
// Application is applied, and nothing else is removed.
func TestMetricsAdoptLegacyDevzone(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	f.r.On("kubectl", metricsGet, fexec.Result{Stdout: []byte("installe")})
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	deployDel := callIndex(f.r.Calls(), "kubectl", "--context", "devzone", "-n", "kube-system", "delete", "deployment", "metrics-server", "--ignore-not-found", "--wait=true")
	svcDel := callIndex(f.r.Calls(), "kubectl", "--context", "devzone", "-n", "kube-system", "delete", "service", "metrics-server", "--ignore-not-found", "--wait=true")
	apply := callIndex(f.r.Calls(), "kubectl", "--context", "devzone", "apply", "-f", "-")
	if deployDel < 0 || svcDel < 0 || apply < 0 || !(deployDel < apply && svcDel < apply) {
		t.Fatalf("legacy objects not replaced before the Application: deploy=%d svc=%d apply=%d", deployDel, svcDel, apply)
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "delete namespace") {
			t.Fatalf("a namespace was deleted: %v", call.Args)
		}
	}
}

// TestMetricsAdoptOtherOwner checks that a metrics-server installed by someone
// else is neither deleted nor overwritten: the command fails with the reason.
func TestMetricsAdoptOtherOwner(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code == 0 {
		t.Fatal("code = 0 over another owner's metrics-server")
	}
	if hasKubectlApply(f) {
		t.Fatal("the Application was applied over another owner's metrics-server")
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && len(call.Args) > 2 && call.Args[len(call.Args)-2] == "delete" {
			t.Fatalf("a deletion ran over another owner's metrics-server: %v", call.Args)
		}
	}
}
