package cluster

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// sequenceRunner returns successive stats responses, so a node can be measured
// before and after the clean; every other call goes to the framework fake.
type sequenceRunner struct {
	*fake.Runner
	stats      []exec.Result
	statsCalls int
}

// Run returns the next stats response, or delegates to the fake runner.
func (s *sequenceRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	if name == "kubectl" && strings.Contains(strings.Join(args, " "), "/stats/summary") {
		if len(s.stats) == 0 {
			return exec.Result{}, fmt.Errorf("no more stats response")
		}
		res := s.stats[0]
		s.stats = s.stats[1:]
		s.statsCalls++
		return res, nil
	}
	return s.Runner.Run(ctx, name, args, opts)
}

// withStats installs a runner with successive stats responses.
func (f *fixture) withStats(stats ...exec.Result) *sequenceRunner {
	s := &sequenceRunner{Runner: f.r, stats: stats}
	f.opts.Runner = s
	return s
}

// alpineNode is a node response with one system image and one usable image.
func alpineNode() exec.Result {
	return exec.Result{Stdout: []byte(`{"status":{"images":[
		{"names":["registry.k8s.io/pause:3.9"]},
		{"names":["library/alpine:3.20"]}
	]}}`)}
}

// isDeleteCall reports whether args delete a pod.
func isDeleteCall(args []string) bool {
	for i, arg := range args {
		if arg == "delete" && i+1 < len(args) && args[i+1] == "pod" {
			return true
		}
	}
	return false
}

// debugArgs is the exact kubectl debug command expected for a node.
func debugArgs(node, image string) []string {
	return []string{"--context", "kind-devzone", "debug", "node/" + node,
		"--image=" + image, "--profile=sysadmin", "--", "chroot", "/host",
		"crictl", "--timeout=300s", "rmi", "--prune"}
}

// TestCleanOneNode checks the image choice, the exact debug command, the pod
// deletion and the bytes freed by a successful clean.
func TestCleanOneNode(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\n")})
	f.withStats(summary(10, 1e11), summary(30, 1e11))
	f.on([]string{"get", "node", "node1", "-o", "json"}, alpineNode())
	f.on(debugArgs("node1", "library/alpine:3.20")[2:], exec.Result{
		Stdout: []byte("Pod/node-debugger-node1-abc created\n")})
	f.on([]string{"get", "pod", "node-debugger-node1-abc", "-o", "jsonpath={.status.phase}"},
		exec.Result{Stdout: []byte("Succeeded")})
	f.on([]string{"logs", "node-debugger-node1-abc"}, exec.Result{
		Stdout: []byte("Deleted image sha256:aaa\nother line\n")})
	f.on([]string{"delete", "pod", "node-debugger-node1-abc", "--ignore-not-found", "--wait=false"},
		exec.Result{})

	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 0 || report.FreedBytes != 2e10 {
		t.Fatalf("report = %+v, want 20 GB freed", report)
	}
	if len(report.Nodes) != 1 || report.Nodes[0].Image != "library/alpine:3.20" {
		t.Fatalf("nodes = %+v", report.Nodes)
	}
	if len(report.Nodes[0].Deleted) != 1 || !strings.Contains(report.Nodes[0].Deleted[0], "Deleted") {
		t.Fatalf("deleted = %+v", report.Nodes[0].Deleted)
	}
	if !strings.Contains(f.out.String(), "✔ cluster clean: 20.0 GB freed on node1") {
		t.Fatalf("output = %q", f.out.String())
	}
	var debugFound, deleteFound bool
	for _, c := range f.r.Calls() {
		if strings.Join(c.Args, "\x00") == strings.Join(debugArgs("node1", "library/alpine:3.20"), "\x00") {
			debugFound = true
		}
		if isDeleteCall(c.Args) {
			deleteFound = true
		}
		if len(c.Opts.Env) != 1 || !strings.HasPrefix(c.Opts.Env[0], "KUBECONFIG=") {
			t.Fatalf("call without explicit KUBECONFIG: %+v", c)
		}
	}
	if !debugFound || !deleteFound {
		t.Fatalf("debug = %v, delete = %v, calls = %+v", debugFound, deleteFound, f.r.Calls())
	}
}

// TestCleanNoUsableImage checks that a node without a shell image is skipped.
func TestCleanNoUsableImage(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\n")})
	f.withStats(summary(10, 1e11))
	f.on([]string{"get", "node", "node1", "-o", "json"}, exec.Result{Stdout: []byte(`{"status":{"images":[
		{"names":["registry.k8s.io/pause:3.9"]},{"names":["kube-proxy:v1.30.0"]}
	]}}`)})

	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 0 || len(report.Nodes) != 1 || !report.Nodes[0].Failed {
		t.Fatalf("report = %+v", report)
	}
	if !strings.Contains(f.out.String(), "no usable image on node1") {
		t.Fatalf("output = %q", f.out.String())
	}
	for _, c := range f.r.Calls() {
		if len(c.Args) > 1 && c.Args[1] == "debug" {
			t.Fatalf("unexpected debug call: %+v", c)
		}
	}
}

// TestCleanFailedPodContinues checks that a failed debug pod is deleted and the
// following node is still cleaned.
func TestCleanFailedPodContinues(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\nnode/node2\n")})
	f.withStats(summary(10, 1e11), summary(10, 1e11), summary(10, 1e11), summary(25, 1e11))
	for _, node := range []string{"node1", "node2"} {
		f.on([]string{"get", "node", node, "-o", "json"}, alpineNode())
	}
	for i, node := range []string{"node1", "node2"} {
		pod := "debug-pod-" + node
		phase := "Succeeded"
		if i == 0 {
			phase = "Failed"
		}
		f.on(debugArgs(node, "library/alpine:3.20")[2:], exec.Result{
			Stdout: []byte("Pod/" + pod + " created\n")})
		f.on([]string{"get", "pod", pod, "-o", "jsonpath={.status.phase}"}, exec.Result{Stdout: []byte(phase)})
		f.on([]string{"logs", pod}, exec.Result{Stdout: []byte("Deleted image sha256:aaa\n")})
		f.on([]string{"delete", "pod", pod, "--ignore-not-found", "--wait=false"}, exec.Result{})
	}

	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 0 || len(report.Nodes) != 2 || report.FreedBytes != 15e9 {
		t.Fatalf("report = %+v", report)
	}
	if !report.Nodes[0].Failed || report.Nodes[1].Failed {
		t.Fatalf("nodes = %+v", report.Nodes)
	}
	deletes := 0
	for _, c := range f.r.Calls() {
		if isDeleteCall(c.Args) {
			deletes++
		}
	}
	if deletes != 2 {
		t.Fatalf("deleted pods = %d, want 2", deletes)
	}
}
