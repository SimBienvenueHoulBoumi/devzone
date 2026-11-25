package kube

import (
	"fmt"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// programServer programs the two config view calls used by IsLocal.
func programServer(t *testing.T, r *fake.Runner, name, server string) string {
	t.Helper()
	home := testkit.TempHome(t)
	conf := filepath.Join(home, ".kube", "config")
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "absent.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", conf)
	r.On("kubectl", []string{"config", "view", "-o",
		fmt.Sprintf("{.contexts[?(@.name==%q)].context.cluster}", name)}, exec.Result{
		Stdout: []byte("cluster-test\n"),
	})
	r.On("kubectl", []string{"config", "view", "-o",
		`{.clusters[?(@.name=="cluster-test")].cluster.server}`}, exec.Result{
		Stdout: []byte(server),
	})
	return conf
}

// TestIsLocalByContextName checks every local context name without a config call.
func TestIsLocalByContextName(t *testing.T) {
	for _, name := range []string{
		"kind-devzone", "kind-other", "docker-desktop", "rancher-desktop", "orbstack", "minikube",
	} {
		t.Run(name, func(t *testing.T) {
			r := withRunner(t)
			if !IsLocal(name) {
				t.Fatalf("IsLocal(%q) = false, want true", name)
			}
			if len(r.Calls()) != 0 {
				t.Fatalf("unexpected kubectl calls: %+v", r.Calls())
			}
		})
	}
}

// TestIsLocalByServer checks every local host, including bracketed IPv6.
func TestIsLocalByServer(t *testing.T) {
	for _, server := range []string{
		"https://127.0.0.1:6443", "https://localhost:6443", "https://[::1]:6443",
		"https://[::1]:6443/path", "https://host.docker.internal:6443",
		"https://127.0.0.1-control-plane:6443", "http://127.0.0.1",
	} {
		t.Run(server, func(t *testing.T) {
			r := withRunner(t)
			conf := programServer(t, r, "host-cluster", server)
			if !IsLocal("host-cluster") {
				t.Fatalf("IsLocal(%q) = false, want true", server)
			}
			for _, c := range r.Calls() {
				if len(c.Opts.Env) != 1 || c.Opts.Env[0] != "KUBECONFIG="+conf {
					t.Fatalf("call %+v has no explicit KUBECONFIG", c)
				}
			}
		})
	}
}

// TestIsLocalRemoteServer checks that a distant API server is refused.
func TestIsLocalRemoteServer(t *testing.T) {
	r := withRunner(t)
	programServer(t, r, "production", "https://cluster.example.test:6443")
	if IsLocal("production") {
		t.Fatal("IsLocal(production) = true, want false")
	}
	if len(r.Calls()) != 2 {
		t.Fatalf("calls = %d, want 2", len(r.Calls()))
	}
}

// TestIsLocalMissingConfig checks that an unknown context is not local.
func TestIsLocalMissingConfig(t *testing.T) {
	r := withRunner(t)
	programServer(t, r, "empty", "https://127.0.0.1:6443")
	r.On("kubectl", []string{"config", "view", "-o",
		`{.contexts[?(@.name=="unknown")].context.cluster}`}, exec.Result{})
	if IsLocal("unknown") {
		t.Fatal("IsLocal(unknown) = true, want false")
	}
}
