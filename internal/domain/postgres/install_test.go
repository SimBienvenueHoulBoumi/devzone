package postgres

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// noSecret programs a missing postgres-admin secret so install creates one.
func (f *fixture) noSecret() {
	f.on([]string{"get", "secret", "postgres-admin"}, execResultCode(1))
}

// execResultCode returns a failed command result.
func execResultCode(code int) exec.Result { return exec.Result{Code: code} }

// TestInstallCreatesKind checks the full install path on a fresh dedicated
// kind cluster: namespace, secret, chart, rollout, relay and ready lines.
func TestInstallCreatesKind(t *testing.T) {
	f := newFixture(t)
	f.saveState("postgres=off", "cluster=kind-devzone")
	f.contextReady("kind-devzone", "kind-devzone", "kind-devzone")
	f.noSecret()
	f.programChart("5Gi")
	f.r.On("kind", []string{"get", "clusters"}, exec.Result{})
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	out := f.out.String()
	for _, want := range []string{
		"▶ Creating the kind devzone cluster (about 1 min)…",
		"▶ PostgreSQL on cluster kind-devzone (namespace devzone-postgres)…",
		"▶ Waiting for PostgreSQL (timeout 300s)…",
		"✔ PostgreSQL ready: 127.0.0.1:5432 in the container",
		"  Database for a project: devzone postgres create <project>",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output %q misses %q", out, want)
		}
	}
	calls := f.r.Calls()
	assertCall(t, calls, "kind", []string{"create", "cluster", "--name", "devzone", "--wait", "120s"})
	assertCall(t, calls, "kubectl", f.adminArgs("kind-devzone", []string{"apply", "-f", "-"}))
	assertCall(t, calls, "kubectl", []string{"--context", "devzone", "-n", ns, "create", "secret", "generic",
		"postgres-admin", "--from-file=password=" + filepath.Join(f.root, "workspace", ".postgres", "admin-password")})
	assertCall(t, calls, "helm", []string{"--kube-context", "devzone", "upgrade", "--install", "postgres",
		filepath.Join(filepath.Dir(f.codeRoot), "charts", "devzone-postgres"), "-n", ns, "--set", "size=5Gi"})
	if len(f.launches) != 1 || f.launches[0].ports[0] != "5432:5432" || f.launches[0].ctxName != "kind-devzone" {
		t.Fatalf("relay launches = %+v", f.launches)
	}
}

// TestInstallOnHostCluster checks that a host cluster install never creates a
// kind cluster and uses the administrator context of that cluster.
func TestInstallOnHostCluster(t *testing.T) {
	f := newFixture(t)
	f.saveState("postgres=off", "cluster=host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.noSecret()
	f.programChart("5Gi")
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kind" && len(call.Args) > 0 && call.Args[0] == "create" {
			t.Fatalf("unexpected kind creation: %+v", call)
		}
	}
	assertCall(t, f.r.Calls(), "kubectl", f.adminArgs("host-cluster",
		[]string{"create", "namespace", ns, "--dry-run=client", "-o", "yaml"}))
}

// TestInstallUnreachableCluster checks that an unreachable chosen cluster
// stops the install before any resource is created.
func TestInstallUnreachableCluster(t *testing.T) {
	f := newFixture(t)
	f.saveState("postgres=off", "cluster=remote")
	f.onRaw([]string{"--context", "remote", "--request-timeout=3s", "get", "--raw", "/readyz"}, exec.Result{Code: 1})
	if code := Run(nil, f.opts, []string{"install"}); code != 1 {
		t.Fatalf("install: code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "cluster remote unreachable") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("unexpected helm call: %+v", call)
		}
	}
}

// TestInstallExistingSecret checks that an existing secret is never
// regenerated, and is copied to a 600 file without being displayed.
func TestInstallExistingSecret(t *testing.T) {
	f := newFixture(t)
	f.saveState("postgres=off", "cluster=host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.on([]string{"get", "secret", "postgres-admin"}, exec.Result{})
	f.on([]string{"get", "secret", "postgres-admin", "-o", "jsonpath={.data.password}"},
		exec.Result{Stdout: []byte("YWRtaW4tZXhpc3RhbnQ=")})
	f.programChart("5Gi")
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	path := filepath.Join(f.root, "workspace", ".postgres", "admin-password")
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "admin-existant" {
		t.Fatalf("admin-password = %q, err %v", data, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v, err %v", info, err)
	}
	if strings.Contains(f.out.String()+f.errOut.String(), "admin-existant") {
		t.Fatal("the secret was displayed")
	}
	for _, call := range f.r.Calls() {
		if len(call.Args) > 2 && call.Args[len(call.Args)-3] == "create" && strings.Contains(strings.Join(call.Args, " "), "postgres-admin") {
			t.Fatalf("secret recreated: %+v", call)
		}
	}
}

// TestUninstallRemovesNamespace checks the admin deletion, the secret removal
// and the release of an empty dedicated kind cluster.
func TestUninstallRemovesNamespace(t *testing.T) {
	f := newFixture(t)
	f.activeOn("kind-devzone")
	f.onAdmin("kind-devzone", []string{"delete", "namespace", ns, "--wait=true"}, exec.Result{})
	f.r.On("kind", []string{"get", "clusters"}, exec.Result{Stdout: []byte("devzone\n")})
	f.onAdmin("kind-devzone", []string{"get", "namespaces", "-l",
		"app.kubernetes.io/managed-by=devzone", "-o", "name"}, exec.Result{})
	secrets := filepath.Join(f.root, "workspace", ".postgres")
	if err := os.MkdirAll(secrets, 0o700); err != nil {
		t.Fatal(err)
	}
	if code := Run(nil, f.opts, []string{"uninstall"}); code != 0 {
		t.Fatalf("uninstall: code %d, stderr %q", code, f.errOut.String())
	}
	assertCall(t, f.r.Calls(), "kubectl", f.adminArgs("kind-devzone", []string{"delete", "namespace", ns, "--wait=true"}))
	assertCall(t, f.r.Calls(), "kind", []string{"delete", "cluster", "--name", "devzone"})
	if _, err := os.Stat(secrets); !os.IsNotExist(err) {
		t.Fatalf("secrets still present: %v", err)
	}
	if !strings.Contains(f.out.String(), "✔ PostgreSQL uninstalled.") {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestUninstallKeepsKind checks that a kind cluster carrying another service
// is not deleted, and that a host cluster is never deleted.
func TestUninstallKeepsKind(t *testing.T) {
	f := newFixture(t)
	f.activeOn("kind-devzone")
	f.r.On("kind", []string{"get", "clusters"}, exec.Result{Stdout: []byte("devzone\n")})
	f.onAdmin("kind-devzone", []string{"get", "namespaces", "-l",
		"app.kubernetes.io/managed-by=devzone", "-o", "name"},
		exec.Result{Stdout: []byte("namespace/autre\n")})
	Run(nil, f.opts, []string{"uninstall"})
	for _, call := range f.r.Calls() {
		if call.Name == "kind" && len(call.Args) > 0 && call.Args[0] == "delete" {
			t.Fatalf("kind cluster deleted: %+v", call)
		}
	}
	f.activeOn("host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.onAdmin("host-cluster", []string{"delete", "namespace", ns, "--wait=true"}, exec.Result{})
	Run(nil, f.opts, []string{"uninstall"})
	assertCall(t, f.r.Calls(), "kubectl", f.adminArgs("host-cluster",
		[]string{"delete", "namespace", ns, "--wait=true"}))
	for _, call := range f.r.Calls() {
		if call.Name == "kind" && len(call.Args) > 0 && call.Args[0] == "delete" {
			t.Fatalf("host cluster deleted: %+v", call)
		}
	}
}
