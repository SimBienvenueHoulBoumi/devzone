package kube

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// programView programs the neutral kubectl answers of a clusters view.
func programView(t *testing.T) (*Kube, *bytes.Buffer) {
	t.Helper()
	r := withRunner(t)
	r.On("kubectl", nil, exec.Result{})
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{
		Stdout: []byte("rancher-desktop\nprod\n"),
	})
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("rancher-desktop\n")})
	r.On("kubectl", []string{"config", "view", "-o", `jsonpath={.contexts[?(@.name=="rancher-desktop")].context.namespace}`}, exec.Result{Stdout: []byte("apps\n")})
	var out bytes.Buffer
	return &Kube{Runner: r}, &out
}

// TestViewTable checks the header, the marks and the remote label.
func TestViewTable(t *testing.T) {
	k, out := programView(t)
	if code := k.View(context.Background(), "rancher-desktop", out, nil); code != 0 {
		t.Fatalf("code = %d", code)
	}
	want := []string{"CONTEXT", "TYPE", "STATE", "NAMESPACE", "★● rancher-desktop", "  prod",
		"remote", "working cluster", "devzone → rancher-desktop"}
	for _, line := range want {
		if !strings.Contains(out.String(), line) {
			t.Fatalf("view = %q, misses %q", out.String(), line)
		}
	}
}

// TestViewNoContext checks the empty view message.
func TestViewNoContext(t *testing.T) {
	k, out := programView(t)
	k.Runner.(*fake.Runner).On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{})
	if code := k.View(context.Background(), "", out, nil); code != 0 ||
		!strings.Contains(out.String(), "no cluster: kind create cluster") {
		t.Fatalf("code = %d, out = %q", code, out.String())
	}
}
