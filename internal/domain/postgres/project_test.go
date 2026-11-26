package postgres

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
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

// TestCreateInvalidName checks that a missing, malformed or reserved project
// name is refused with code 2 and sends no SQL, as in postgres.bats.
func TestCreateInvalidName(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	for _, name := range []string{"", "Task", "1abc", "a-b", "x;drop", "postgres"} {
		if code := Run(nil, f.opts, append([]string{"create"}, name)); code != 2 {
			t.Fatalf("create %q: code %d, want 2", name, code)
		}
	}
	for _, call := range f.r.Calls() {
		if len(call.Args) > 2 && call.Args[2] == "exec" {
			t.Fatalf("SQL was sent: %+v", call)
		}
	}
}

// TestCreate checks the role, the database, the closed access, the 600 file
// and that the password is never displayed.
func TestCreate(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	if code := Run(nil, f.opts, []string{"create", "taskmanager"}); code != 0 {
		t.Fatalf("create: code %d, stderr %q", code, f.errOut.String())
	}
	sql := ""
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && strings.Join(call.Args, " ") == strings.Join(
			[]string{"--context", "devzone", "-n", ns, "exec", "-i", "postgres-0", "-c", "postgres", "--",
				"psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-U", "postgres"}, " ") {
			sql = stdinOf(t, call)
		}
	}
	for _, want := range []string{"CREATE ROLE taskmanager LOGIN", "CREATE DATABASE taskmanager OWNER taskmanager",
		"REVOKE CONNECT ON DATABASE taskmanager FROM PUBLIC", "GRANT CONNECT ON DATABASE taskmanager TO taskmanager"} {
		if !strings.Contains(sql, want) {
			t.Errorf("SQL %q misses %q", sql, want)
		}
	}
	path := filepath.Join(f.root, "workspace", ".postgres", "taskmanager.env")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{"DB_HOST=127.0.0.1", "DB_PORT=5432", "DB_NAME=taskmanager",
		"DB_USER=taskmanager", "DB_PASSWORD=pwsecret1", "DB_URL=jdbc:postgresql://127.0.0.1:5432/taskmanager"} {
		if !strings.Contains(string(data), line+"\n") {
			t.Errorf("env file misses %q: %q", line, data)
		}
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
	if strings.Contains(f.out.String()+f.errOut.String(), "pwsecret") {
		t.Fatal("password displayed")
	}
	if !strings.Contains(f.out.String(), path) {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestCreateKeepsPassword checks that a second create keeps the password and
// that --new-password replaces it, as in postgres.bats.
func TestCreateKeepsPassword(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	path := filepath.Join(f.root, "workspace", ".postgres", "taskmanager.env")
	for _, code := range []int{Run(nil, f.opts, []string{"create", "taskmanager"}),
		Run(nil, f.opts, []string{"create", "taskmanager"})} {
		if code != 0 {
			t.Fatalf("create: code %d", code)
		}
	}
	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), "DB_PASSWORD=pwsecret1\n") {
		t.Fatalf("password not kept: %q", data)
	}
	if code := Run(nil, f.opts, []string{"create", "taskmanager", "--new-password"}); code != 0 {
		t.Fatalf("renew: code %d", code)
	}
	data, _ = os.ReadFile(path)
	if !strings.Contains(string(data), "DB_PASSWORD=pwsecret2\n") {
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

// repoDevcontainer returns the shell library folder of this checkout.
func repoDevcontainer(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the test file")
	}
	return filepath.Join(filepath.Dir(file), "..", "..", "..", ".devcontainer")
}

// TestPasswordFollowsAccounts checks that .password follows create, renew and
// delete, with no secret on the command line.
func TestPasswordFollowsAccounts(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.opts.Runner = &hybridRunner{sequenceRunner: f.r}
	passwordFile := filepath.Join(f.root, ".password")
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"create", "taskmanager"}, "postgres:taskmanager\t127.0.0.1:5432/taskmanager\ttaskmanager\tpwsecret1"},
		{[]string{"create", "taskmanager", "--new-password"}, "postgres:taskmanager\t127.0.0.1:5432/taskmanager\ttaskmanager\tpwsecret2"},
	} {
		if code := Run(nil, f.opts, tc.args); code != 0 {
			t.Fatalf("%v: code %d, stderr %q", tc.args, code, f.errOut.String())
		}
		data, err := os.ReadFile(passwordFile)
		if err != nil || !strings.Contains(string(data), tc.want) {
			t.Fatalf(".password = %q, want %q, err %v", data, tc.want, err)
		}
	}
	if code := Run(nil, f.opts, []string{"delete", "taskmanager", "--yes"}); code != 0 {
		t.Fatalf("delete: code %d", code)
	}
	if _, err := os.Stat(passwordFile); !os.IsNotExist(err) {
		t.Fatalf(".password still present: %v", err)
	}
}
