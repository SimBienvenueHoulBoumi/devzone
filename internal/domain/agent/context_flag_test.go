package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// contextCall records one runner call and the environment it received.
type contextCall struct {
	args []string
	env  []string
}

// contextFake answers the kubeconfig query with the configured context list.
type contextFake struct {
	contexts string
	calls    []contextCall
}

// Run implements Runner without starting any program.
func (f *contextFake) Run(ctx context.Context, name string, args []string, opts Opts) (Result, error) {
	f.calls = append(f.calls, contextCall{args: append([]string(nil), args...), env: append([]string(nil), opts.Env...)})
	if len(args) > 0 && args[0] == "config" && args[1] == "get-contexts" {
		return Result{Stdout: []byte(f.contexts)}, nil
	}
	return Result{}, nil
}

// TestAgentKCUsesCurrentContext checks that no context flag is sent when the
// kubeconfig does not declare the services context.
func TestAgentKCUsesCurrentContext(t *testing.T) {
	f := &contextFake{contexts: "kind-poste\n"}
	if res := AgentKC(context.Background(), f, "get", "pods"); res.Code != 0 {
		t.Fatalf("AgentKC code = %d", res.Code)
	}
	last := f.calls[len(f.calls)-1]
	if strings.Contains(strings.Join(last.args, " "), "--context") {
		t.Fatalf("context forced without declaration: %q", last.args)
	}
}

// TestOpenCodeLaunchUsesCurrentKubeconfig checks that the context lookup reads
// the workstation kubeconfig, then exports it without an undeclared flag.
func TestOpenCodeLaunchUsesCurrentKubeconfig(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "")
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".kube", "config"), []byte("apiVersion: v1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	brief := filepath.Join(dir, "brief.md")
	writeFileT(t, brief, "brief\n")
	f := &contextFake{contexts: "kind-poste\n"}
	_, err := OpenCodeLaunch(context.Background(), f, nil, &captureCoreStarter{},
		dir, "big-pickle", brief, filepath.Join(dir, "journal.log"), dir, LocalModel{})
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range f.calls {
		joined := strings.Join(call.args, " ")
		if strings.HasPrefix(joined, "config view") && strings.Contains(joined, "--context") {
			t.Fatalf("context forced without declaration: %q", joined)
		}
		if len(call.args) > 1 && call.args[0] == "config" && call.args[1] == "get-contexts" &&
			!strings.Contains(strings.Join(call.env, " "), "KUBECONFIG="+filepath.Join(home, ".kube", "config")) {
			t.Fatalf("context query did not read the workstation kubeconfig: %q", call.env)
		}
	}
}

// TestAgentKCUsesConfiguredContext checks that the shared name override is
// carried by the kubectl call when kubeconfig declares that context.
func TestAgentKCUsesConfiguredContext(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	f := &contextFake{contexts: "kind-poste\nkind-lab\n"}
	AgentKC(context.Background(), f, "get", "pods")
	last := f.calls[len(f.calls)-1]
	want := []string{"--context", "kind-lab", "--namespace", "devzone-workspace", "get", "pods"}
	for i, arg := range want {
		if i >= len(last.args) || last.args[i] != arg {
			t.Fatalf("args = %q, want %q", last.args, want)
		}
	}
}
