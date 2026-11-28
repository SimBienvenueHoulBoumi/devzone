package podcmd

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestMetricsIsPorted checks that the launcher can route metrics to the Go
// binary, which decides between an Application and the existing shell path.
func TestMetricsIsPorted(t *testing.T) {
	if code := Run([]string{"handles", "metrics"}, io.Discard, io.Discard); code != 0 {
		t.Fatalf("handles metrics: code %d, want 0", code)
	}
}

// TestMetricsApplicationPath checks that an active Argo CD creates the
// dependency Application without reaching a real cluster or network.
func TestMetricsApplicationPath(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_POD_SCRIPT", filepath.Join(root, ".devcontainer", "devzone"))
	t.Setenv("DEVZONE_CONTEXT", "")
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte("argocd=on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".devcontainer"), 0o755); err != nil {
		t.Fatal(err)
	}
	pins := "METRICS_SERVER_CHART_VERSION=3.14.0\nMETRICS_SERVER_VERSION=v0.9.0\n"
	if err := os.WriteFile(filepath.Join(root, ".devcontainer", "versions.env"), []byte(pins), 0o644); err != nil {
		t.Fatal(err)
	}
	// The code folder is the one of DEVZONE_POD_SCRIPT, which must exist to be used
	if err := os.WriteFile(filepath.Join(root, ".devcontainer", "devzone"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte(fexec.ContextName() + "\n")})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "get", "namespace", "devzone-argocd"}, fexec.Result{})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-metrics-server"},
		fexec.Result{Code: 1, Stderr: []byte("Error from server (NotFound): applications.argoproj.io \"devzone-metrics-server\" not found")})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "-n", "kube-system", "get", "deployment", "metrics-server",
		"-o", "jsonpath={.metadata.labels.devzone}"}, fexec.Result{Code: 1, Stderr: []byte("Error from server (NotFound)")})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "apply", "-f", "-"}, fexec.Result{})
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	ctx := &cli.Context{Out: out, Err: errOut, Runner: r}
	if code := runMetrics(ctx); code != 0 {
		t.Fatalf("metrics: code %d, err = %q", code, errOut.String())
	}
	applied := ""
	for _, call := range r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm was called: %v", call.Args)
		}
		if call.Name == "kubectl" && strings.Join(call.Args, " ") == "--context "+fexec.ContextName()+" apply -f -" && call.Opts.Stdin != nil {
			data, err := io.ReadAll(call.Opts.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			applied = string(data)
		}
	}
	if !strings.Contains(applied, "name: devzone-metrics-server") || !strings.Contains(applied, "targetRevision: 3.14.0") {
		t.Fatalf("no pinned dependency Application: %q", applied)
	}
}

// metricsRemoveCase runs "metrics remove" with the given arguments, Argo CD
// active, and returns the kubectl calls that delete the devzone Application.
func metricsRemoveCase(t *testing.T, args []string) (int, int) {
	t.Helper()
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_POD_SCRIPT", filepath.Join(root, ".devcontainer", "devzone"))
	t.Setenv("DEVZONE_CONTEXT", "")
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte("argocd=on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".devcontainer"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".devcontainer", "devzone"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte(fexec.ContextName() + "\n")})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "get", "namespace", "devzone-argocd"}, fexec.Result{})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "-n", "kube-system", "get", "deployment", "metrics-server",
		"-o", "jsonpath={.metadata.labels.devzone}"}, fexec.Result{Code: 1, Stderr: []byte("Error from server (NotFound)")})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "-n", "kube-system", "get", "deployment", "metrics-server"},
		fexec.Result{Code: 1, Stderr: []byte("Error from server (NotFound)")})
	r.On("kubectl", []string{"--context", fexec.ContextName(), "-n", "devzone-argocd", "delete", "application.argoproj.io",
		"devzone-metrics-server", "--ignore-not-found", "--wait=true"}, fexec.Result{})
	ctx := &cli.Context{Out: &bytes.Buffer{}, Err: &bytes.Buffer{}, Runner: r, Args: args}
	code := runMetrics(ctx)
	if code != 0 {
		t.Fatalf("metrics %v: code %d, err = %q", args, code, ctx.Err.(*bytes.Buffer).String())
	}
	deleted, removals := 0, 0
	for _, call := range r.Calls() {
		if call.Name == "helm" || (call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "delete -f")) {
			removals++
		}
		if call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "delete application.argoproj.io devzone-metrics-server") {
			deleted++
		}
	}
	return deleted, removals
}

// TestMetricsRemoveDeletesApplication checks that "metrics remove" without a
// context, with Argo CD active, also deletes the devzone Application.
func TestMetricsRemoveDeletesApplication(t *testing.T) {
	deleted, removals := metricsRemoveCase(t, []string{"remove"})
	if deleted != 1 {
		t.Fatalf("Application deletions = %d, want 1", deleted)
	}
	if removals != 0 {
		t.Fatalf("unexpected manifest removal: %d", removals)
	}
}

// TestMetricsRemoveWithContextKeepsApplication checks that "metrics remove
// <context>" leaves the devzone Application alone: the user targeted another
// context, so only the direct removal applies there.
func TestMetricsRemoveWithContextKeepsApplication(t *testing.T) {
	deleted, _ := metricsRemoveCase(t, []string{"remove", "devzone"})
	if deleted != 0 {
		t.Fatalf("Application deleted by a context-targeted remove: %d calls", deleted)
	}
}
