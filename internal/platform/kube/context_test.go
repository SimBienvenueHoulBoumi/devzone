package kube

import (
	"context"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestConfigContextsTrimsNames checks the raw config query without a kubeconfig override.
func TestConfigContextsTrimsNames(t *testing.T) {
	r := withRunner(t)
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{
		Stdout: []byte("local\nremote\n\n"),
	})
	names, err := Kube{Runner: r}.ConfigContexts(context.Background())
	if err != nil || len(names) != 2 || names[0] != "local" || names[1] != "remote" {
		t.Fatalf("names = %v, err = %v", names, err)
	}
	if calls := r.Calls(); len(calls) != 1 || len(calls[0].Opts.Env) != 0 {
		t.Fatalf("calls = %+v, want one call without KUBECONFIG", calls)
	}
}

// TestCurrentContextAndNamespace checks the two config reads of the prompt and the view.
func TestCurrentContextAndNamespace(t *testing.T) {
	r := withRunner(t)
	k := Kube{Runner: r}
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("local\n")})
	r.On("kubectl", []string{"config", "view", "-o", `jsonpath={.contexts[?(@.name=="local")].context.namespace}`}, exec.Result{Stdout: []byte("apps\n")})
	if got := k.CurrentContext(context.Background()); got != "local" {
		t.Fatalf("CurrentContext = %q", got)
	}
	if got := k.ContextNamespace(context.Background(), "local"); got != "apps" {
		t.Fatalf("ContextNamespace = %q", got)
	}
}

// TestUseContextAndSetNamespace checks that the two writes keep the shell arguments.
func TestUseContextAndSetNamespace(t *testing.T) {
	r := withRunner(t)
	k := Kube{Runner: r}
	r.On("kubectl", []string{"config", "use-context", "remote"}, exec.Result{})
	r.On("kubectl", []string{"config", "set-context", "local", "--namespace", "apps"}, exec.Result{})
	if err := k.UseContext(context.Background(), "remote"); err != nil {
		t.Fatal(err)
	}
	if err := k.SetNamespace(context.Background(), "local", "apps"); err != nil {
		t.Fatal(err)
	}
}

// TestReachableTimeout checks the request timeout passed to the readiness probe.
func TestReachableTimeout(t *testing.T) {
	r := withRunner(t)
	r.On("kubectl", []string{"--context", "local", "--request-timeout=5s", "get", "--raw", "/readyz"}, exec.Result{})
	if !(Kube{Runner: r}).ReachableTimeout(context.Background(), "local", "5s") {
		t.Fatal("ReachableTimeout = false, want true")
	}
}

// TestHostContextsUsesExplicitKubeconfig checks that the host contexts are read
// from one explicit kubeconfig, never from the combined environment.
func TestHostContextsUsesExplicitKubeconfig(t *testing.T) {
	host := hostFile(t)
	r := withRunner(t)
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("host-a\n")})
	names, err := Kube{Runner: r}.HostContexts(context.Background(), host)
	if err != nil || len(names) != 1 || names[0] != "host-a" {
		t.Fatalf("names = %v, err = %v", names, err)
	}
	if calls := r.Calls(); len(calls) != 1 || len(calls[0].Opts.Env) != 1 ||
		calls[0].Opts.Env[0] != "KUBECONFIG="+host {
		t.Fatalf("calls = %+v, want KUBECONFIG=%s", calls, host)
	}
}
