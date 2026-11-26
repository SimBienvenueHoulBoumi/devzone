package argocd

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writePins writes versions.env in the code folder of the fixture, where the
// dependency reads its chart version.
func writePins(t *testing.T, root, text string) {
	t.Helper()
	dir := filepath.Join(root, ".devcontainer")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "versions.env"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestDependencyApplicationFromOfficialSource checks that metrics-server is
// declared from the official chart at a pinned version, with no helm call and
// no change to a devzone chart.
func TestDependencyApplicationFromOfficialSource(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writePins(t, f.root, "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n")
	if code := f.run("dependency", "metrics-server", "on"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	manifest := ""
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm was called for a dependency: %q", joinedArgs(call))
		}
		if call.Name == "kubectl" && strings.Join(call.Args, " ") == "--context devzone apply -f -" && call.Opts.Stdin != nil {
			data, err := io.ReadAll(call.Opts.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			manifest = string(data)
		}
	}
	for _, want := range []string{
		"kind: Application", "name: devzone-metrics-server", "devzone.io/kind: dependency",
		"repoURL: " + metricsRepo, "chart: metrics-server", "targetRevision: 3.14.0",
		"name: args[0]", `value: "--kubelet-insecure-tls"`,
		"namespace: kube-system", "prune: true", "selfHeal: true",
	} {
		if !strings.Contains(manifest, want) {
			t.Fatalf("manifest misses %q:\n%s", want, manifest)
		}
	}
}

// TestDependencyApplicationOff checks that disabling the dependency removes
// the Application only, leaving the objects of the cluster to its finalizer.
func TestDependencyApplicationOff(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	if code := f.run("dependency", "metrics-server", "off"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	if !hasCall(f.r.Calls(), "kubectl", devzoneKubectl("-n", gitopsNS, "delete", "application.argoproj.io",
		"devzone-metrics-server", "--ignore-not-found", "--wait=true")...) {
		t.Fatalf("Application was not deleted: %v", f.r.Calls())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" || (call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "delete namespace")) {
			t.Fatalf("an object was removed directly: %q", joinedArgs(call))
		}
	}
}

// TestDependencyNoPinNoApply checks that a missing pin stops the dependency
// before anything reaches the cluster, with the file named in the error.
func TestDependencyNoPinNoApply(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	if code := f.run("dependency", "metrics-server", "on"); code == 0 {
		t.Fatal("code = 0 without versions.env")
	}
	if !strings.Contains(f.err.String(), "versions.env") {
		t.Fatalf("error does not name the file: %q", f.err.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && strings.Join(call.Args, " ") == "--context devzone apply -f -" {
			t.Fatal("an Application was applied without a pin")
		}
	}
}

// TestRepositoryPinsMetricsServer checks the shipped declaration: chart 3.14.0
// carries application v0.9.0, the version the local script also installs.
func TestRepositoryPinsMetricsServer(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", ".devcontainer", "versions.env"))
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(string(data), "METRICS_SERVER_CHART_VERSION"); got != "3.14.0" {
		t.Fatalf("chart = %q, want 3.14.0", got)
	}
	if got := envValue(string(data), "METRICS_SERVER_VERSION"); got != "v0.9.0" {
		t.Fatalf("application = %q, want v0.9.0", got)
	}
}
