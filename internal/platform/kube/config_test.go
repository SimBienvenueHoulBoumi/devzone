package kube

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// withRunner installs a fake runner for the package helpers until the test ends.
func withRunner(t *testing.T) *fake.Runner {
	t.Helper()
	old := DefaultRunner
	r := testkit.FakeRunner(t)
	DefaultRunner = r
	t.Cleanup(func() { DefaultRunner = old })
	return r
}

// hostFile creates the host kubeconfig of the test home.
func hostFile(t *testing.T) string {
	t.Helper()
	home := testkit.TempHome(t)
	host := filepath.Join(home, ".kube", "hote.config")
	if err := os.MkdirAll(filepath.Dir(host), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(host, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_HOST", host)
	return host
}

// TestAdminKubeconfigContextInHostFile checks the admin context found in the host file.
func TestAdminKubeconfigContextInHostFile(t *testing.T) {
	host := hostFile(t)
	t.Setenv("DEVZONE_KUBE_CONFIG", "/tmp/account.config")
	r := withRunner(t)
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{
		Stdout: []byte("kind-other\nhost-cluster\n"),
	})
	if got := AdminKubeconfig("host-cluster"); got != host {
		t.Fatalf("AdminKubeconfig = %q, want %q", got, host)
	}
	calls := r.Calls()
	if len(calls) != 1 || len(calls[0].Opts.Env) != 1 || calls[0].Opts.Env[0] != "KUBECONFIG="+host {
		t.Fatalf("kubectl calls = %+v, want one call with KUBECONFIG=%s", calls, host)
	}
}

// TestAdminKubeconfigContextAbsent checks the fallback when the host file does not list the context.
func TestAdminKubeconfigContextAbsent(t *testing.T) {
	hostFile(t)
	t.Setenv("DEVZONE_KUBE_CONFIG", "/tmp/account.config")
	r := withRunner(t)
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{
		Stdout: []byte("kind-devzone\n"),
	})
	if got := AdminKubeconfig("host-cluster"); got != "/tmp/account.config" {
		t.Fatalf("AdminKubeconfig = %q, want the account file", got)
	}
}

// TestAdminKubeconfigFileAbsent checks the fallback without any kubectl call.
func TestAdminKubeconfigFileAbsent(t *testing.T) {
	home := testkit.TempHome(t)
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "absent.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", "/tmp/account.config")
	r := withRunner(t)
	if got := AdminKubeconfig("host-cluster"); got != "/tmp/account.config" {
		t.Fatalf("AdminKubeconfig = %q, want the account file", got)
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("unexpected calls: %+v", r.Calls())
	}
}
