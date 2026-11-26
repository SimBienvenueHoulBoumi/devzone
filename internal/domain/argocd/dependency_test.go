package argocd

import (
	"io"
	"strings"
	"testing"
)

// TestDependencyApplicationFromOfficialSource checks that metrics-server is
// declared from the official chart at a pinned version, with no helm call and
// no change to a devzone chart.
func TestDependencyApplicationFromOfficialSource(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
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
		"repoURL: " + metricsRepo, "chart: metrics-server", "targetRevision: " + metricsVersion,
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
