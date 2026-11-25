package mysql

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// noStatefulSet programs a missing StatefulSet so install creates the chart.
func (f *fixture) noStatefulSet() {
	f.on([]string{"get", "statefulset", "mysql"}, exec.Result{Code: 1})
}

// programPVCs programs the list of PVCs returned by kubectl.
func (f *fixture) programPVCs(names ...string) {
	f.on([]string{"get", "pvc", "-o", "jsonpath=" + volumeJSONPath},
		exec.Result{Stdout: []byte(strings.Join(names, "\n") + "\n")})
}

// TestInstallClaimDonnees checks a fresh install with no existing PVC.
func TestInstallClaimDonnees(t *testing.T) {
	f := newFixture(t)
	f.saveState("mysql=off", "cluster=kind-devzone")
	f.contextReady("kind-devzone", "kind-devzone", "kind-devzone")
	f.noSecret()
	f.noStatefulSet()
	f.programChart("donnees")
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	if !strings.Contains(f.out.String(), "✔ MySQL ready: 127.0.0.1:3306 in the container") {
		t.Fatalf("output = %q", f.out.String())
	}
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", ns, "create", "secret", "generic",
		"mysql-admin", "--from-file=password=" + filepath.Join(f.root, "workspace", ".mysql", "admin-password")})
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", ns, "rollout", "status", "statefulset/mysql", "--timeout=10s"})
}

// TestInstallClaimReuse checks that the prefix of an existing PVC is reused.
func TestInstallClaimReuse(t *testing.T) {
	f := newFixture(t)
	f.saveState("mysql=off", "cluster=host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.noSecret()
	f.noStatefulSet()
	f.programPVCs("data-mysql-0")
	f.programChart("data")
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	found := false
	for _, call := range f.r.Calls() {
		if call.Name == "helm" && strings.Contains(strings.Join(call.Args, " "), "--set claim=data") {
			found = true
		}
	}
	if !found {
		t.Fatalf("claim data not applied: %+v", f.r.Calls())
	}
}

// TestInstallSeveralVolumes checks the refusal with the list and the command.
func TestInstallSeveralVolumes(t *testing.T) {
	f := newFixture(t)
	f.saveState("mysql=off", "cluster=host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.noSecret()
	f.noStatefulSet()
	f.programPVCs("data-mysql-0", "donnees-mysql-0")
	if code := Run(nil, f.opts, []string{"install"}); code != 2 {
		t.Fatalf("install: code %d, want 2", code)
	}
	for _, want := range []string{"data-mysql-0", "donnees-mysql-0", "devzone mysql volume <name>"} {
		if !strings.Contains(f.errOut.String(), want) {
			t.Errorf("stderr %q misses %q", f.errOut.String(), want)
		}
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" && len(call.Args) > 1 && call.Args[1] != "template" {
			t.Fatalf("chart applied despite the refusal: %+v", call)
		}
	}
}

// TestInstallAdopts checks that an existing installation keeps root.env and
// its volume, and that the chart is not applied again.
func TestInstallAdopts(t *testing.T) {
	f := newFixture(t)
	f.saveState("mysql=off", "cluster=host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.rootReady("mdproot")
	secrets := filepath.Join(f.root, "workspace", ".mysql")
	if err := os.MkdirAll(secrets, 0o700); err != nil {
		t.Fatal(err)
	}
	rootEnv := "MYSQL_HOST=127.0.0.1\nMYSQL_PORT=3306\nMYSQL_USER=root\nMYSQL_PASSWORD=mdproot\n"
	if err := os.WriteFile(filepath.Join(secrets, "root.env"), []byte(rootEnv), 0o600); err != nil {
		t.Fatal(err)
	}
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	if !strings.Contains(f.out.String(), "adopted (volume and root.env kept)") {
		t.Fatalf("output = %q", f.out.String())
	}
	data, _ := os.ReadFile(filepath.Join(secrets, "root.env"))
	if string(data) != rootEnv {
		t.Fatalf("root.env changed: %q", data)
	}
	admin, _ := os.ReadFile(filepath.Join(secrets, "admin-password"))
	if string(admin) != "mdproot" {
		t.Fatalf("admin-password = %q", admin)
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" && len(call.Args) > 1 && call.Args[1] != "template" {
			t.Fatalf("unexpected helm install: %+v", call)
		}
	}
}

// TestDeleteData checks the namespace deletion, the preserved root.env and the
// failure marker removal.
func TestDeleteData(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.onAdmin("host-cluster", []string{"delete", "namespace", ns, "--wait=true"}, exec.Result{})
	secrets := filepath.Join(f.root, "workspace", ".mysql")
	if err := os.MkdirAll(secrets, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(secrets, "root.env"), []byte("MYSQL_PASSWORD=mdproot\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	marker := f.statePath + "-failed-mysql"
	if err := os.WriteFile(marker, []byte("mysql\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := Run(nil, f.opts, []string{"delete-data", "--yes"}); code != 0 {
		t.Fatalf("delete-data: code %d, stderr %q", code, f.errOut.String())
	}
	assertCall(t, f.r.Calls(), "kubectl", f.adminArgs("host-cluster", []string{"delete", "namespace", ns, "--wait=true"}))
	if _, err := os.Stat(filepath.Join(secrets, "root.env")); err != nil {
		t.Fatalf("root.env removed: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("failure marker kept: %v", err)
	}
	if !strings.Contains(f.out.String(), "✔ namespace devzone-mysql and volume deleted; workspace/.mysql/root.env kept") {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestDeleteDataConfirmation checks the refusal outside a terminal and the
// abort on Enter before any deletion.
func TestDeleteDataConfirmation(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	if code := Run(nil, f.opts, []string{"delete-data"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "confirmation needs a terminal: devzone mysql delete-data --yes") {
		t.Fatalf("delete-data: code %d, stderr %q", code, f.errOut.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "delete namespace") {
			t.Fatalf("namespace deleted despite the refusal: %+v", call)
		}
	}
}

// TestDeleteDataTerminalAbort checks that Enter in a terminal aborts the
// deletion of the namespace and its volumes, as mysql.bats did.
func TestDeleteDataTerminalAbort(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.opts.Interactive = true
	f.opts.Stdin = strings.NewReader("\n")
	if code := Run(nil, f.opts, []string{"delete-data"}); code != 0 || !strings.Contains(f.out.String(), "Aborted") {
		t.Fatalf("abort: code %d, output %q", code, f.out.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "delete namespace") {
			t.Fatalf("namespace deleted despite the abort: %+v", call)
		}
	}
}
