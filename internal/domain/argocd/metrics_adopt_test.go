package argocd

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// metricsGet is the read of the legacy mark on the kube-system deployment.
var metricsGet = []string{"--context", "devzone", "-n", "kube-system", "get", "deployment", "metrics-server",
	"-o", "jsonpath={.metadata.labels.devzone}"}

// metricsAppGet is the read of the Application devzone-metrics-server.
var metricsAppGet = []string{"--context", "devzone", "-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-metrics-server"}

// metricsApply is the apply of the rendered Application.
var metricsApply = []string{"--context", "devzone", "apply", "-f", "-"}

// absentMetrics makes the deployment read answer NotFound, as on a fresh cluster.
func absentMetrics(f *modFixture) {
	f.r.On("kubectl", metricsGet, fexec.Result{Code: 1, Stderr: []byte(`Error from server (NotFound): deployments.apps "metrics-server" not found`)})
}

// absentApplication makes the Application read answer NotFound.
func absentApplication(f *modFixture) {
	f.r.On("kubectl", metricsAppGet, fexec.Result{Code: 1, Stderr: []byte(`Error from server (NotFound): applications.argoproj.io "devzone-metrics-server" not found`)})
}

// presentApplication makes the Application read find devzone-metrics-server.
func presentApplication(f *modFixture) {
	f.r.On("kubectl", metricsAppGet, fexec.Result{Stdout: []byte("application.argoproj.io/devzone-metrics-server")})
}

// hasKubectlApply reports whether the Application was applied.
func hasKubectlApply(f *modFixture) bool {
	return hasCall(f.r.Calls(), "kubectl", "--context", "devzone", "apply", "-f", "-")
}

// hasDelete reports whether any kubectl command carried the argument "delete".
func hasDelete(calls []fake.Call) bool {
	for _, call := range calls {
		if call.Name != "kubectl" {
			continue
		}
		for _, arg := range call.Args {
			if arg == "delete" {
				return true
			}
		}
	}
	return false
}

// TestMetricsAdoptAbsent checks that a fresh cluster gets the Application
// without any deletion.
func TestMetricsAdoptAbsent(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	absentApplication(f)
	absentMetrics(f)
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	if !hasKubectlApply(f) {
		t.Fatal("no Application applied on a fresh cluster")
	}
	if hasDelete(f.r.Calls()) {
		t.Fatal("a deletion ran on a fresh cluster")
	}
}

// TestMetricsAdoptLegacyDevzone checks that the copy marked by devzone is
// replaced by the chart: the two legacy objects are deleted, then the
// Application is applied, and nothing else is removed.
func TestMetricsAdoptLegacyDevzone(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	absentApplication(f)
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
// else is neither deleted nor overwritten: the command fails and says that
// nothing was changed.
func TestMetricsAdoptOtherOwner(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	absentApplication(f)
	f.r.On("kubectl", metricsGet, fexec.Result{Stdout: []byte("autre-outil")})
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code == 0 {
		t.Fatal("code = 0 over another owner's metrics-server")
	}
	if !strings.Contains(f.err.String(), "nothing was changed") {
		t.Fatalf("refusal does not say that nothing was changed: %q", f.err.String())
	}
	if hasKubectlApply(f) {
		t.Fatal("the Application was applied over another owner's metrics-server")
	}
	if hasDelete(f.r.Calls()) {
		t.Fatal("a deletion ran over another owner's metrics-server")
	}
}

// TestMetricsAdoptIdempotent checks that a rerun, once the Application exists,
// only applies it: the Deployment created by Argo CD carries no devzone label
// and must not be taken for another owner.
func TestMetricsAdoptIdempotent(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	presentApplication(f)
	f.r.On("kubectl", metricsGet, fexec.Result{})
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	if !hasKubectlApply(f) {
		t.Fatal("the Application was not applied on a rerun")
	}
	if hasDelete(f.r.Calls()) {
		t.Fatal("a deletion ran on a rerun")
	}
	if callIndex(f.r.Calls(), "kubectl", metricsGet...) >= 0 {
		t.Fatal("the owner check ran although the Application exists")
	}
}

// TestMetricsAdoptAppReadError checks that a failed read of the Application,
// other than NotFound, stops the command before anything is deleted or applied.
func TestMetricsAdoptAppReadError(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	f.r.On("kubectl", metricsAppGet, fexec.Result{Code: 1, Stderr: []byte("Error from server (Forbidden): applications.argoproj.io is forbidden")})
	f.r.On("kubectl", metricsGet, fexec.Result{Stdout: []byte("installe")})
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code == 0 {
		t.Fatal("code = 0 although the Application read failed")
	}
	if !strings.Contains(f.err.String(), "devzone-metrics-server") {
		t.Fatalf("read error message does not name the Application: %q", f.err.String())
	}
	if hasDelete(f.r.Calls()) || hasKubectlApply(f) {
		t.Fatal("something was deleted or applied after a failed read")
	}
}

// TestMetricsAdoptCRDAbsent checks that a cluster without the Application CRD
// is treated like an absent Application: the owner check then decides.
func TestMetricsAdoptCRDAbsent(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	f.r.On("kubectl", metricsAppGet, fexec.Result{Code: 1, Stderr: []byte(`error: the server doesn't have a resource type "application.argoproj.io"`)})
	absentMetrics(f)
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	if !hasKubectlApply(f) {
		t.Fatal("the Application was not applied without the CRD")
	}
}

// TestMetricsAdoptPartialFailure checks that legacy objects deleted before a
// failed apply are reported, and that a rerun succeeds once they are gone.
func TestMetricsAdoptPartialFailure(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	absentApplication(f)
	f.r.On("kubectl", metricsGet, fexec.Result{Stdout: []byte("installe")})
	f.r.On("kubectl", metricsApply, fexec.Result{Code: 1, Stderr: []byte("apply refused")})
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code == 0 {
		t.Fatal("code = 0 although the apply failed")
	}
	msg := f.err.String()
	if !strings.Contains(msg, "metrics-server is removed") || !strings.Contains(msg, "run the command again") {
		t.Fatalf("first run does not say that metrics-server is removed and must be rerun: %q", msg)
	}

	// Rerun: the legacy Deployment is gone and the apply succeeds.
	f.r.On("kubectl", metricsGet, fexec.Result{Code: 1, Stderr: []byte(`Error from server (NotFound): deployments.apps "metrics-server" not found`)})
	f.r.On("kubectl", metricsApply, fexec.Result{})
	f.err.Reset()
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("rerun code = %d, err = %q", code, f.err.String())
	}
}
