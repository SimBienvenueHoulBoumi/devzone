package postgres

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// livePID starts a process that stays alive until the test ends, so the relay
// PID file can be seen as active by status.
func livePID(t *testing.T) int {
	t.Helper()
	cmd := osexec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	return cmd.Process.Pid
}

// writePID writes a relay PID file in the isolated workspace.
func (f *fixture) writePID(t *testing.T, pid int) {
	t.Helper()
	dir := filepath.Join(f.root, "workspace", ".postgres")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "relais.pid"), []byte(strings.TrimSpace(strconv.Itoa(pid))+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestStatusDisabled checks the exact disabled line without a chosen cluster.
func TestStatusDisabled(t *testing.T) {
	f := newFixture(t)
	if code := Run(nil, f.opts, []string{"status"}); code != 0 {
		t.Fatalf("status: code %d", code)
	}
	if f.out.String() != "disabled\n" {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestStatusReadyAndRelayStopped checks the three ready states and the count
// of project databases, byte for byte as in postgres.bats.
func TestStatusReadyAndRelayStopped(t *testing.T) {
	f := newFixture(t)
	if code := Run(nil, f.opts, []string{"status"}); code != 0 || f.out.String() != "disabled\n" {
		t.Fatalf("disabled: code %d, output %q", code, f.out.String())
	}
	f.out.Reset()
	f.saveState("postgres=on", "cluster=host-cluster")
	f.onAdmin("host-cluster", []string{"get", "namespace", ns}, exec.Result{})
	f.on([]string{"get", "statefulset", "postgres", "-o", "jsonpath={.status.readyReplicas}"},
		exec.Result{Stdout: []byte("1\n")})
	f.on([]string{"exec", "-i", "postgres-0", "-c", "postgres", "--", "psql",
		"-v", "ON_ERROR_STOP=1", "-X", "-q", "-U", "postgres", "-At",
		"-c", "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')"},
		exec.Result{Stdout: []byte("2\n")})
	if code := Run(nil, f.opts, []string{"status"}); code != 0 || f.out.String() != "ready on host-cluster, relay stopped: devzone apply\n" {
		t.Fatalf("status: code %d, output %q", code, f.out.String())
	}
	f.writePID(t, livePID(t))
	f.out.Reset()
	if code := Run(nil, f.opts, []string{"status"}); code != 0 || f.out.String() != "ready on host-cluster: 127.0.0.1:5432, 2 database(s)\n" {
		t.Fatalf("status: code %d, output %q", code, f.out.String())
	}
}

// TestStatusFailed checks the failure line when the StatefulSet is not ready.
func TestStatusFailed(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.on([]string{"get", "statefulset", "postgres", "-o", "jsonpath={.status.readyReplicas}"}, exec.Result{})
	if code := Run(nil, f.opts, []string{"status"}); code != 0 || f.out.String() != "failed on host-cluster: devzone apply\n" {
		t.Fatalf("status: code %d, output %q", code, f.out.String())
	}
}

// TestList checks the aligned databases and owners, and the empty list line.
func TestList(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	args := []string{"--context", "devzone", "-n", ns, "exec", "-i", "postgres-0", "-c", "postgres", "--",
		"psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-U", "postgres", "-At", "-F", " ",
		"-c", "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY 1"}
	f.r.On("kubectl", args, exec.Result{Stdout: []byte("taskmanager taskmanager\n")})
	if code := Run(nil, f.opts, []string{"list"}); code != 0 {
		t.Fatalf("list: code %d", code)
	}
	if !strings.Contains(f.out.String(), "taskmanager") || !strings.Contains(f.out.String(), "owner taskmanager") {
		t.Fatalf("output = %q", f.out.String())
	}
	f.out.Reset()
	f.r.On("kubectl", args, exec.Result{})
	Run(nil, f.opts, []string{"list"})
	if f.out.String() != "  (no database: devzone postgres create <project>)\n" {
		t.Fatalf("empty output = %q", f.out.String())
	}
}

// TestDisabledRefusal checks that create, list and psql refuse a module that
// is not installed, with the same message and code 2.
func TestDisabledRefusal(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=host-cluster")
	f.onAdmin("host-cluster", []string{"get", "namespace", ns}, exec.Result{Code: 1})
	for _, args := range [][]string{{"create", "taskmanager"}, {"list"}, {"psql"}} {
		f.errOut.Reset()
		if code := Run(nil, f.opts, args); code != 2 {
			t.Fatalf("%v: code %d, want 2", args, code)
		}
		if !strings.Contains(f.errOut.String(), "devzone enable postgres") {
			t.Fatalf("%v: stderr %q", args, f.errOut.String())
		}
	}
}

// TestPSQL checks the interactive console arguments with and without a project.
func TestPSQL(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.opts.TTY = true
	Run(nil, f.opts, []string{"psql", "taskmanager"})
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", ns, "exec", "-i", "-t",
		"postgres-0", "-c", "postgres", "--", "psql", "-U", "taskmanager", "-d", "taskmanager"})
	f.out.Reset()
	Run(nil, f.opts, []string{"psql"})
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", ns, "exec", "-i", "-t",
		"postgres-0", "-c", "postgres", "--", "psql", "-U", "postgres"})
}

// TestDelete checks the refusal outside a terminal, the accepted SQL with
// --yes and the abort in a terminal.
func TestDelete(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	path := filepath.Join(f.root, "workspace", ".postgres", "taskmanager.env")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("DB_PASSWORD=pwsecret1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code := Run(nil, f.opts, []string{"delete", "taskmanager"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "devzone postgres delete taskmanager --yes") {
		t.Fatalf("delete without --yes: code %d, stderr %q", code, f.errOut.String())
	}
	f.errOut.Reset()
	f.opts.Interactive = true
	f.opts.Stdin = strings.NewReader("\n")
	if code := Run(nil, f.opts, []string{"delete", "taskmanager"}); code != 0 ||
		!strings.Contains(f.out.String(), "Abandon: nothing was deleted.") {
		t.Fatalf("delete abort: code %d, output %q", code, f.out.String())
	}
	f.opts.Stdin = strings.NewReader("y\n")
	if code := Run(nil, f.opts, []string{"delete", "taskmanager", "--yes"}); code != 0 {
		t.Fatalf("delete --yes: code %d, stderr %q", code, f.errOut.String())
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("env file still present: %v", err)
	}
	sql := ""
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "exec -i postgres-0") {
			sql += stdinOf(t, call)
		}
	}
	if !strings.Contains(sql, "DROP DATABASE IF EXISTS taskmanager WITH (FORCE)") ||
		!strings.Contains(sql, "DROP ROLE IF EXISTS taskmanager") {
		t.Fatalf("SQL = %q", sql)
	}
}
