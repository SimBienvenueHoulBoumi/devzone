package postgres

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestAdminPasswordFollowsInstall checks that the grouped credentials file
// gains the admin account on install and loses it on uninstall.
func TestAdminPasswordFollowsInstall(t *testing.T) {
	f := newFixture(t)
	f.saveState("postgres=off", "cluster=host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.noSecret()
	f.programChart("5Gi")
	f.opts.Runner = &hybridRunner{sequenceRunner: f.r}
	if code := Run(nil, f.opts, []string{"install"}); code != 0 {
		t.Fatalf("install: code %d, stderr %q", code, f.errOut.String())
	}
	passwordFile := filepath.Join(f.root, ".password")
	data, err := os.ReadFile(passwordFile)
	if err != nil || !strings.Contains(string(data), "postgres\t127.0.0.1:5432\tpostgres\tpwsecret1") {
		t.Fatalf(".password = %q, err %v", data, err)
	}
	if code := Run(nil, f.opts, []string{"uninstall"}); code != 0 {
		t.Fatalf("uninstall: code %d, stderr %q", code, f.errOut.String())
	}
	data, err = os.ReadFile(passwordFile)
	if err == nil && strings.Contains(string(data), "postgres\t127.0.0.1:5432") {
		t.Fatalf("admin account still in .password: %q", data)
	}
}

// TestDeleteTerminalAbort checks that Enter in a terminal deletes nothing and
// returns the same "Abandon" line as postgres.bats.
func TestDeleteTerminalAbort(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.opts.Interactive = true
	f.opts.Stdin = strings.NewReader("\n")
	if code := Run(nil, f.opts, []string{"delete", "taskmanager"}); code != 0 ||
		!strings.Contains(f.out.String(), "Abandon: nothing was deleted.") {
		t.Fatalf("delete: code %d, output %q", code, f.out.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "exec -i postgres-0") {
			t.Fatalf("SQL sent after abort: %+v", call)
		}
	}
}
