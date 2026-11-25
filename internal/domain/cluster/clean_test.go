package cluster

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// fixture holds the fake runner and the state of one clean test.
type fixture struct {
	r    *fake.Runner
	root string
	out  strings.Builder
	opts Options
}

// newFixture creates an isolated devzone root with a fake runner.
func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_WORKSPACE", "")
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(root, "hote.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", filepath.Join(root, "config"))
	f := &fixture{r: testkit.FakeRunner(t), root: root}
	f.opts = Options{
		Runner:       f.r,
		Out:          &f.out,
		Root:         root,
		PollInterval: time.Millisecond,
	}
	return f
}

// saveCluster writes the chosen cluster in the state file.
func (f *fixture) saveCluster(t *testing.T, name string) {
	t.Helper()
	data := ""
	if name != "" {
		data = "cluster=" + name + "\n"
	}
	if err := os.WriteFile(filepath.Join(f.root, ".devzone.modules"), []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

// on programs a kubectl call on the services context.
func (f *fixture) on(args []string, res exec.Result) {
	f.r.On("kubectl", append([]string{"--context", "kind-devzone"}, args...), res)
}

// onRaw programs a kubectl call with the exact arguments given.
func (f *fixture) onRaw(args []string, res exec.Result) {
	f.r.On("kubectl", args, res)
}

// summary returns a fake stats/summary response with the given free percentage.
func summary(percent float64, capacity int64) exec.Result {
	available := int64(float64(capacity) * percent / 100)
	return exec.Result{Stdout: []byte(fmt.Sprintf(
		`{"node":{"fs":{"availableBytes":%d,"capacityBytes":%d}}}`, available, capacity))}
}

// TestCleanNoClusterKey checks that a state without a cluster does nothing.
func TestCleanNoClusterKey(t *testing.T) {
	f := newFixture(t)
	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 0 || report.Context != "" || len(report.Nodes) != 0 {
		t.Fatalf("report = %+v, want an empty report", report)
	}
	if len(f.r.Calls()) != 0 || f.out.Len() != 0 {
		t.Fatalf("calls = %+v, output = %q", f.r.Calls(), f.out.String())
	}
}

// TestCleanWorkspacePod checks that the workstation pod never cleans a cluster.
func TestCleanWorkspacePod(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Skipped || report.Code != 0 {
		t.Fatalf("report = %+v, want a skipped run", report)
	}
	if !strings.Contains(f.out.String(), "skipped inside the workspace pod") {
		t.Fatalf("output = %q", f.out.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("unexpected calls: %+v", f.r.Calls())
	}
}

// TestCleanDistantCluster checks that a services cluster on the network is left alone.
func TestCleanDistantCluster(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "production")
	f.onRaw([]string{"config", "view", "-o", `jsonpath={.contexts[?(@.name=="production")].context.cluster}`},
		exec.Result{Stdout: []byte("remote\n")})
	f.onRaw([]string{"config", "view", "-o", `jsonpath={.clusters[?(@.name=="remote")].cluster.server}`},
		exec.Result{Stdout: []byte("https://cluster.example.test:6443")})
	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Skipped || report.Code != 0 {
		t.Fatalf("report = %+v, want a skipped run", report)
	}
	if !strings.Contains(f.out.String(), "is not local") {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestCleanAllAboveThreshold checks the informational line and the absence of debug pods.
func TestCleanAllAboveThreshold(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\nnode/node2\n")})
	f.on([]string{"get", "--raw", "/api/v1/nodes/node1/proxy/stats/summary"}, summary(20, 1e11))
	f.on([]string{"get", "--raw", "/api/v1/nodes/node2/proxy/stats/summary"}, summary(40, 1e11))
	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 0 || len(report.Nodes) != 2 || report.FreedBytes != 0 {
		t.Fatalf("report = %+v", report)
	}
	if !strings.Contains(f.out.String(), "ℹ cluster disk: 20.0% free, nothing to clean") {
		t.Fatalf("output = %q", f.out.String())
	}
	for _, c := range f.r.Calls() {
		if c.Name == "kubectl" && len(c.Args) > 1 && c.Args[1] == "debug" {
			t.Fatalf("unexpected debug call: %+v", c)
		}
	}
}
