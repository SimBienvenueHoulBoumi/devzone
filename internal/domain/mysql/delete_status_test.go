package mysql

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestDelete checks the refusal, the abort and the SQL of a confirmed delete.
func TestDelete(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	path := filepath.Join(f.root, "workspace", ".mysql", "datayer.env")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("MYSQL_PASSWORD=mdpmysql1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code := Run(nil, f.opts, []string{"delete", "datayer"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "devzone mysql delete datayer --yes") {
		t.Fatalf("delete: code %d, stderr %q", code, f.errOut.String())
	}
	f.opts.Interactive = true
	f.opts.Stdin = strings.NewReader("n\n")
	if code := Run(nil, f.opts, []string{"delete", "datayer"}); code != 0 || !strings.Contains(f.out.String(), "Aborted") {
		t.Fatalf("abort: code %d, output %q", code, f.out.String())
	}
	if code := Run(nil, f.opts, []string{"delete", "datayer", "--yes"}); code != 0 {
		t.Fatalf("delete --yes: code %d, stderr %q", code, f.errOut.String())
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("env file kept: %v", err)
	}
	sql := ""
	for _, call := range f.r.Calls() {
		if isSQLCall(call) {
			sql += stdinOf(t, call)
		}
	}
	if !strings.Contains(sql, "DROP DATABASE IF EXISTS datayer") ||
		!strings.Contains(sql, "DROP USER IF EXISTS 'datayer'@'%'") {
		t.Fatalf("SQL = %q", sql)
	}
}

// livePID starts a process that stays alive until the test ends.
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
	dir := filepath.Join(f.root, "workspace", ".mysql")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "relais.pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestStatus checks disabled, relay stopped and ready with the database count.
func TestStatus(t *testing.T) {
	f := newFixture(t)
	if code := Run(nil, f.opts, []string{"status"}); code != 0 || f.out.String() != "disabled\n" {
		t.Fatalf("disabled: code %d, output %q", code, f.out.String())
	}
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	f.out.Reset()
	f.on([]string{"get", "statefulset", "mysql", "-o", "jsonpath={.status.readyReplicas}"},
		exec.Result{Stdout: []byte("1\n")})
	if code := Run(nil, f.opts, []string{"status"}); code != 0 ||
		f.out.String() != "ready on host-cluster, relay stopped: devzone apply\n" {
		t.Fatalf("relay stopped: code %d, output %q", code, f.out.String())
	}
	f.writePID(t, livePID(t))
	f.out.Reset()
	f.r.On("kubectl", []string{"--context", "devzone", "-n", ns, "exec", "-i", "mysql-0",
		"-c", "mysql", "--", "mysql", "-uroot", "-pmdproot", "-N", "-B", "-e", "SHOW DATABASES"},
		exec.Result{Stdout: []byte("datayer\ninformation_schema\n")})
	if code := Run(nil, f.opts, []string{"status"}); code != 0 ||
		f.out.String() != "ready on host-cluster: 127.0.0.1:3306, 1 database(s)\n" {
		t.Fatalf("ready: code %d, output %q", code, f.out.String())
	}
}

// TestList checks the aligned database lines and the empty list message.
func TestList(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	f.r.On("kubectl", []string{"--context", "devzone", "-n", ns, "exec", "-i", "mysql-0",
		"-c", "mysql", "--", "mysql", "-uroot", "-pmdproot", "-N", "-B", "-e", "SHOW DATABASES"},
		exec.Result{Stdout: []byte("datayer\ninformation_schema\n")})
	if code := Run(nil, f.opts, []string{"list"}); code != 0 {
		t.Fatalf("list: code %d", code)
	}
	if !strings.Contains(f.out.String(), "datayer") || strings.Contains(f.out.String(), "information_schema") {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestNoDeprecatedWarning checks that English subcommand names never warn.
func TestNoDeprecatedWarning(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	for _, args := range [][]string{{"create", "datayer", "--new-password"}, {"status"}, {"list"},
		{"delete", "datayer", "--yes"}, {"delete-data", "--yes"}} {
		f.errOut.Reset()
		if code := Run(nil, f.opts, args); code != 0 {
			t.Fatalf("%v: code %d, stderr %q", args, code, f.errOut.String())
		}
		if strings.Contains(f.errOut.String(), "deprecated") {
			t.Fatalf("%v: warning %q", args, f.errOut.String())
		}
		f.activeOn("host-cluster")
	}
}
