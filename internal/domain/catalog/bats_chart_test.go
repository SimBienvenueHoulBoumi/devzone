package catalog

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/helm"
)

// TestChartInstallAdoptsExistingObjects checks the helm-direct path: the chart
// values, the ownership annotations of existing objects and no deletion.
func TestChartInstallAdoptsExistingObjects(t *testing.T) {
	f := newFixture(t)
	sets := joinedFlags("size=7Gi")
	manifest := "kind: StatefulSet\n  storage: 7Gi\n"
	f.r.On("helm", append([]string{"template", "mysql", f.chart, "-n", "devzone-mysql"}, sets...),
		fexec.Result{Stdout: []byte(manifest)})
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-mysql", "get", "-f", "-",
		"-o", "name", "--ignore-not-found"}, fexec.Result{Stdout: []byte("statefulset.apps/mysql\n")})
	f.r.On("helm", append([]string{"--kube-context", "devzone", "upgrade", "--install", "mysql", f.chart, "-n", "devzone-mysql"}, sets...),
		fexec.Result{})
	_, code := helm.Install(context.Background(), f.r, f.codeRoot, "mysql", "devzone-mysql", []string{"size=7Gi"}, &f.errOut)
	if code != 0 {
		t.Fatalf("chart install: code %d, err %q", code, f.errOut.String())
	}
	calls := f.r.Calls()
	assertCall(t, calls, "kubectl", "--context", "devzone", "-n", "devzone-mysql",
		"annotate", "statefulset.apps/mysql", "meta.helm.sh/release-name=mysql",
		"meta.helm.sh/release-namespace=devzone-mysql", "--overwrite")
	assertCall(t, calls, "kubectl", "--context", "devzone", "-n", "devzone-mysql",
		"label", "statefulset.apps/mysql", "app.kubernetes.io/managed-by=Helm", "--overwrite")
	for _, call := range calls {
		if strings.Contains(strings.Join(call.Args, " "), "delete") {
			t.Fatalf("existing object deleted: %s", formatCall(call))
		}
	}
	i := callIndex(calls, "kubectl", "--context", "devzone", "-n", "devzone-mysql",
		"get", "-f", "-", "-o", "name", "--ignore-not-found")
	if i < 0 {
		t.Fatal("manifest not sent to kubectl")
	}
}

// TestChartInstallFreshNamespace checks that nothing is adopted when no object
// of the rendered chart exists yet.
func TestChartInstallFreshNamespace(t *testing.T) {
	f := newFixture(t)
	sets := joinedFlags("claim=donnees")
	f.r.On("helm", append([]string{"template", "mysql", f.chart, "-n", "devzone-mysql"}, sets...),
		fexec.Result{Stdout: []byte("kind: StatefulSet\n")})
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-mysql", "get", "-f", "-",
		"-o", "name", "--ignore-not-found"}, fexec.Result{})
	f.r.On("helm", append([]string{"--kube-context", "devzone", "upgrade", "--install", "mysql", f.chart, "-n", "devzone-mysql"}, sets...),
		fexec.Result{})
	_, code := helm.Install(context.Background(), f.r, f.codeRoot, "mysql", "devzone-mysql", []string{"claim=donnees"}, &f.errOut)
	if code != 0 {
		t.Fatalf("chart install: code %d", code)
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "annotate") {
			t.Fatalf("adopted nothing on a fresh namespace: %s", formatCall(call))
		}
	}
}

// TestChartInstallMissingChart checks the refusal before any tool runs.
func TestChartInstallMissingChart(t *testing.T) {
	f := newFixture(t)
	_, code := helm.Install(context.Background(), f.r, f.codeRoot, "nosuch", "devzone-nosuch", nil, &f.errOut)
	if code != 2 {
		t.Fatalf("chart install: code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "chart charts/devzone-nosuch missing") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls before the refusal: %+v", f.r.Calls())
	}
}

// TestChartInstallTemplateFailure checks a non-zero status of helm template.
func TestChartInstallTemplateFailure(t *testing.T) {
	f := newFixture(t)
	f.r.On("helm", nil, fexec.Result{Code: 1, Stderr: []byte("render failed\n")})
	_, code := helm.Install(context.Background(), f.r, f.codeRoot, "mysql", "devzone-mysql", nil, &f.errOut)
	if code != 1 {
		t.Fatalf("chart install: code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "render failed") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestChartPathFromCodeRoot checks that the chart is read beside the shell
// entry point, whatever the devzone root and the current folder are.
func TestChartPathFromCodeRoot(t *testing.T) {
	f := newFixture(t)
	f.opts.CodeRoot = filepath.Join(f.root, "other", "nested")
	f.r.On("helm", nil, fexec.Result{})
	_, code := helm.Install(context.Background(), f.r, f.opts.CodeRoot, "mysql", "devzone-mysql", nil, &f.errOut)
	if code != 2 {
		t.Fatalf("chart install: code %d, want 2 for a chart outside the code tree", code)
	}
}
