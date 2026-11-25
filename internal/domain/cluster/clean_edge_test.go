package cluster

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestCleanLowDiskAfter checks the warning and status 3 after a low clean.
func TestCleanLowDiskAfter(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\n")})
	f.withStats(summary(3, 1e11), summary(4, 1e11))
	f.on([]string{"get", "node", "node1", "-o", "json"}, alpineNode())
	f.on(debugArgs("node1", "docker.io/library/alpine:3.20")[2:], exec.Result{
		Stdout: []byte("Pod/low-pod created\n")})
	f.on([]string{"get", "pod", "low-pod", "-o", "jsonpath={.status.phase}"},
		exec.Result{Stdout: []byte("Succeeded")})
	f.on([]string{"logs", "low-pod"}, exec.Result{Stdout: []byte("Deleted image sha256:aaa\n")})
	f.on([]string{"delete", "pod", "low-pod", "--ignore-not-found", "--wait=false"}, exec.Result{})

	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 3 {
		t.Fatalf("code = %d, want 3", report.Code)
	}
	want := "⚠ cluster disk: 4.0% free on node1 after cleaning: enlarge the disk of the local cluster"
	if !strings.Contains(f.out.String(), want) {
		t.Fatalf("output = %q, want %q", f.out.String(), want)
	}
}

// TestCleanDryRun checks that no debug pod is created and the plan is printed.
func TestCleanDryRun(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.opts.DryRun = true
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\n")})
	f.withStats(summary(10, 1e11))
	f.on([]string{"get", "node", "node1", "-o", "json"}, alpineNode())

	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 0 || report.FreedBytes != 0 {
		t.Fatalf("report = %+v", report)
	}
	if !strings.Contains(f.out.String(), "[dry-run]: would clean node1 with docker.io/library/alpine:3.20") {
		t.Fatalf("output = %q", f.out.String())
	}
	for _, c := range f.r.Calls() {
		if len(c.Args) > 1 && (c.Args[1] == "debug" || c.Args[0] == "delete") {
			t.Fatalf("dry-run made a change: %+v", c)
		}
	}
}

// TestCleanDryRunLowDisk checks that a low disk is reported in dry-run too.
func TestCleanDryRunLowDisk(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.opts.DryRun = true
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\n")})
	f.withStats(summary(3, 1e11))
	f.on([]string{"get", "node", "node1", "-o", "json"}, alpineNode())
	report, err := Clean(context.Background(), f.opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Code != 3 {
		t.Fatalf("code = %d, want 3", report.Code)
	}
}

// TestCleanQuiet checks that the informational line is absent with --quiet.
func TestCleanQuiet(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.opts.Quiet = true
	f.on([]string{"get", "nodes", "-o", "name"}, exec.Result{Stdout: []byte("node/node1\n")})
	f.withStats(summary(20, 1e11))
	if _, err := Clean(context.Background(), f.opts); err != nil {
		t.Fatal(err)
	}
	if f.out.Len() != 0 {
		t.Fatalf("output = %q, want none", f.out.String())
	}
}

// TestCleanCallError checks that a kubectl that cannot start is the only error.
func TestCleanCallError(t *testing.T) {
	f := newFixture(t)
	f.saveCluster(t, "kind-devzone")
	f.r.OnError("kubectl", []string{"--context", "kind-devzone", "get", "nodes", "-o", "name"},
		exec.Result{}, errors.New("kubectl not found"))
	report, err := Clean(context.Background(), f.opts)
	if err == nil || !strings.Contains(err.Error(), "kubectl not found") {
		t.Fatalf("err = %v, want the call error", err)
	}
	if report.Code != 0 {
		t.Fatalf("report = %+v", report)
	}
}
