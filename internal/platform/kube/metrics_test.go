package kube

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// programMetrics programs the neutral kubectl answers of one metrics run.
func programMetrics(t *testing.T, contexts string) (*Kube, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	r := withRunner(t)
	r.On("kubectl", nil, exec.Result{})
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte(contexts)})
	var out, errOut bytes.Buffer
	return &Kube{Runner: r}, &out, &errOut
}

// withProgrammedMetrics programs one answer of the fake runner.
func withProgrammedMetrics(t *testing.T, k *Kube, args []string, res exec.Result) {
	t.Helper()
	r, ok := k.Runner.(interface {
		On(string, []string, exec.Result)
	})
	if !ok {
		t.Fatal("runner cannot be programmed")
	}
	r.On("kubectl", args, res)
}

// readinessArgs are the readiness probes of an explicitly requested context.
func readinessArgs(name string) []string {
	return []string{"--context", name, "--request-timeout=5s", "get", "--raw", "/readyz"}
}

// TestMetricsInstall checks the manifest, patch and mark of a fresh install.
func TestMetricsInstall(t *testing.T) {
	k, out, errOut := programMetrics(t, "local\n")
	withProgrammedMetrics(t, k, []string{"--context", "local", "--request-timeout=5s", "get", "apiservice", "v1beta1.metrics.k8s.io"}, exec.Result{Code: 1})
	code := k.Metrics(context.Background(), []string{"local"}, out, errOut)
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
	want := "metrics-server : installed (v0.9.0): local (metrics within ~1 min)"
	if !strings.Contains(out.String(), want) {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
	joined := ""
	for _, call := range k.Runner.(*fake.Runner).Calls() {
		joined += strings.Join(call.Args, " ") + "\n"
	}
	if !strings.Contains(joined, "apply -f "+MetricsManifest) ||
		!strings.Contains(joined, "--kubelet-insecure-tls") ||
		!strings.Contains(joined, "devzone=installe") {
		t.Fatalf("calls = %q", joined)
	}
}

// TestMetricsAlreadyPresent checks that an existing Metrics API is left alone.
func TestMetricsAlreadyPresent(t *testing.T) {
	k, out, _ := programMetrics(t, "local\n")
	withProgrammedMetrics(t, k, []string{"--context", "local", "--request-timeout=5s", "get", "apiservice", "v1beta1.metrics.k8s.io"}, exec.Result{})
	code := k.Metrics(context.Background(), []string{"local"}, out, nil)
	if code != 0 || !strings.Contains(out.String(), "metrics-server : already present: local") {
		t.Fatalf("code = %d, out = %q", code, out.String())
	}
}

// TestMetricsRefusals checks unknown and unreachable requested contexts.
func TestMetricsRefusals(t *testing.T) {
	k, _, errOut := programMetrics(t, "local\n")
	if code := k.Metrics(context.Background(), []string{"unknown"}, nil, errOut); code != 1 ||
		!strings.Contains(errOut.String(), "unknown context: unknown") {
		t.Fatalf("unknown: code %d, err %q", code, errOut.String())
	}
	errOut.Reset()
	withProgrammedMetrics(t, k, readinessArgs("local"), exec.Result{Code: 1})
	if code := k.Metrics(context.Background(), []string{"local"}, nil, errOut); code != 1 ||
		!strings.Contains(errOut.String(), "cluster unreachable: local") {
		t.Fatalf("unreachable: code %d, err %q", code, errOut.String())
	}
}

// TestMetricsRemove checks that only marked installations are removed.
func TestMetricsRemove(t *testing.T) {
	k, out, errOut := programMetrics(t, "local\nother\n")
	markArgs := func(name string) []string {
		return []string{"--context", name, "-n", "kube-system", "get", "deployment", "metrics-server", "-o", "jsonpath={.metadata.labels.devzone}"}
	}
	withProgrammedMetrics(t, k, markArgs("local"), exec.Result{Stdout: []byte("installe")})
	withProgrammedMetrics(t, k, markArgs("other"), exec.Result{})
	withProgrammedMetrics(t, k, []string{"--context", "other", "-n", "kube-system", "get", "deployment", "metrics-server"}, exec.Result{})
	code := k.Metrics(context.Background(), []string{"retirer", "local", "other"}, out, errOut)
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "metrics-server removed (v0.9.0) : local") ||
		!strings.Contains(errOut.String(), "metrics-server present without a devzone mark, left: other") {
		t.Fatalf("out = %q, err = %q", out.String(), errOut.String())
	}
}

// TestMetricsNoReachableLocal checks the final message when nothing answers.
func TestMetricsNoReachableLocal(t *testing.T) {
	k, out, _ := programMetrics(t, "host\n")
	code := k.Metrics(context.Background(), nil, out, nil)
	if code != 0 || !strings.Contains(out.String(), "no reachable local cluster") {
		t.Fatalf("code = %d, out = %q", code, out.String())
	}
}
