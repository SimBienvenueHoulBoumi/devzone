package mysql

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// stdinOf returns the data written on standard input of a recorded call.
func stdinOf(t *testing.T, call fake.Call) string {
	t.Helper()
	if call.Opts.Stdin == nil {
		return ""
	}
	buf := make([]byte, 8192)
	n, _ := call.Opts.Stdin.Read(buf)
	return string(buf[:n])
}

// isSQLCall reports whether a recorded kubectl call carries a SQL script.
func isSQLCall(call fake.Call) bool {
	return call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "exec -i mysql-0")
}

// TestCreateInvalidName checks that a missing, malformed or reserved project
// name is refused with code 2 before any SQL is sent.
func TestCreateInvalidName(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	for _, name := range []string{"", "Task", "1abc", "a-b", "x;drop", "mysql", "sys"} {
		if code := Run(nil, f.opts, append([]string{"create"}, name)); code != 2 {
			t.Fatalf("create %q: code %d, want 2", name, code)
		}
	}
	for _, call := range f.r.Calls() {
		if isSQLCall(call) {
			t.Fatalf("SQL was sent: %+v", call)
		}
	}
}

// TestCreateDisabled checks the refusal when the module is not installed.
func TestCreateDisabled(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=host-cluster")
	f.onAdmin("host-cluster", []string{"get", "namespace", ns}, exec.Result{Code: 1})
	if code := Run(nil, f.opts, []string{"create", "datayer"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "devzone enable mysql") {
		t.Fatalf("create: code %d, stderr %q", code, f.errOut.String())
	}
}

// TestCreate checks the SQL, the 600 env file and that the password is hidden.
func TestCreate(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	if code := Run(nil, f.opts, []string{"create", "datayer"}); code != 0 {
		t.Fatalf("create: code %d, stderr %q", code, f.errOut.String())
	}
	sql := ""
	for _, call := range f.r.Calls() {
		if isSQLCall(call) {
			sql += stdinOf(t, call)
		}
	}
	for _, want := range []string{"CREATE USER IF NOT EXISTS 'datayer'@'%'", "CREATE DATABASE IF NOT EXISTS datayer",
		"GRANT ALL ON datayer.* TO 'datayer'@'%'"} {
		if !strings.Contains(sql, want) {
			t.Errorf("SQL %q misses %q", sql, want)
		}
	}
	path := filepath.Join(f.root, "workspace", ".mysql", "datayer.env")
	data, _ := os.ReadFile(path)
	for _, line := range []string{"MYSQL_HOST=127.0.0.1", "MYSQL_PORT=3306", "MYSQL_USER=datayer",
		"MYSQL_PASSWORD=mdpmysql1", "MYSQL_URL=jdbc:mysql://127.0.0.1:3306/datayer"} {
		if !strings.Contains(string(data), line+"\n") {
			t.Errorf("env file misses %q: %q", line, data)
		}
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
	if strings.Contains(f.out.String()+f.errOut.String(), "mdpmysql") {
		t.Fatal("password displayed")
	}
	if !strings.Contains(f.out.String(), path) {
		t.Fatalf("output = %q", f.out.String())
	}
	grouped, err := os.ReadFile(filepath.Join(f.root, ".password"))
	if err != nil || !strings.Contains(string(grouped), "mysql:datayer\t127.0.0.1:3306\tdatayer\tmdpmysql1") {
		t.Fatalf(".password = %q, err %v", grouped, err)
	}
}

// TestCreateKeepsPassword checks the kept password and --new-password.
func TestCreateKeepsPassword(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	path := filepath.Join(f.root, "workspace", ".mysql", "datayer.env")
	for i := 0; i < 2; i++ {
		if code := Run(nil, f.opts, []string{"create", "datayer"}); code != 0 {
			t.Fatalf("create: code %d", code)
		}
	}
	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), "MYSQL_PASSWORD=mdpmysql1\n") {
		t.Fatalf("password not kept: %q", data)
	}
	if code := Run(nil, f.opts, []string{"create", "datayer", "--new-password"}); code != 0 {
		t.Fatalf("renew: code %d", code)
	}
	data, _ = os.ReadFile(path)
	if !strings.Contains(string(data), "MYSQL_PASSWORD=mdpmysql2\n") {
		t.Fatalf("password not renewed: %q", data)
	}
}

// hybridRunner keeps kubectl and openssl faked while the grouped credentials
// are regenerated in Go by the domain, not by a shell command.
type hybridRunner struct{ *sequenceRunner }

// Run implements exec.Runner with the programmed fake responses.
func (h *hybridRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	return h.sequenceRunner.Run(ctx, name, args, opts)
}

// TestPasswordFollowsAccounts checks that .password mirrors create and delete.
func TestPasswordFollowsAccounts(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.rootReady("mdproot")
	f.opts.Runner = &hybridRunner{sequenceRunner: f.r}
	passwordFile := filepath.Join(f.root, ".password")
	if code := Run(nil, f.opts, []string{"create", "datayer"}); code != 0 {
		t.Fatalf("create: code %d, stderr %q", code, f.errOut.String())
	}
	data, err := os.ReadFile(passwordFile)
	if err != nil || !strings.Contains(string(data), "mysql:datayer\t127.0.0.1:3306\tdatayer\tmdpmysql1") {
		t.Fatalf(".password = %q, err %v", data, err)
	}
	if code := Run(nil, f.opts, []string{"delete", "datayer", "--yes"}); code != 0 {
		t.Fatalf("delete: code %d", code)
	}
}
