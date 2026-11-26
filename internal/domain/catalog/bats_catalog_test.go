package catalog

import (
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestList shows the applications with the label of their wanted state.
func TestList(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=off")
	if code := f.run("list"); code != 0 {
		t.Fatalf("list: code %d", code)
	}
	if got := f.out.String(); !strings.Contains(got, "mysql") || !strings.Contains(got, "off available") {
		t.Fatalf("list output = %q", got)
	}
}

// TestJSON has an applications array with the same fields as catalog.sh.
func TestJSON(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=off")
	if code := f.run("json"); code != 0 {
		t.Fatalf("json: code %d", code)
	}
	for _, want := range []string{`"name":"mysql"`, `"active":false`, `"state":"available"`,
		`"port":"3306"`, `"description":"Shared MySQL, one database per project"`, `"command":"devzone enable mysql"`} {
		if !strings.Contains(f.out.String(), want) {
			t.Fatalf("json output %q misses %s", f.out.String(), want)
		}
	}
}

// TestSyncDelegatesToState checks that sync goes through the Go state command
// with the isolated state file and the same lock as the shell.
func TestSyncDelegatesToState(t *testing.T) {
	f := newFixture(t)
	f.saveState("autre=off")
	f.r.On("bash", []string{f.script, "state", "catalog-sync"}, fexec.Result{})
	if code := f.run("sync"); code != 0 {
		t.Fatalf("sync: code %d", code)
	}
	calls := f.r.Calls()
	assertCall(t, calls, "bash", f.script, "state", "catalog-sync")
	i := callIndex(calls, "bash", f.script, "state", "catalog-sync")
	want := "DEVZONE_STATE=" + f.statePath
	found := false
	for _, v := range calls[i].Opts.Env {
		if v == want {
			found = true
		}
	}
	if !found {
		t.Fatalf("sync env = %v, want %s", calls[i].Opts.Env, want)
	}
}

// TestSyncPropagatesFailure checks a non-zero code of the delegated state command.
func TestSyncPropagatesFailure(t *testing.T) {
	f := newFixture(t)
	f.saveState("mysql=off")
	f.r.On("bash", []string{f.script, "state", "catalog-sync"}, fexec.Result{Code: 3, Stderr: []byte("locked\n")})
	if code := f.run("sync"); code != 3 {
		t.Fatalf("sync: code %d, want 3", code)
	}
	if !strings.Contains(f.errOut.String(), "locked") {
		t.Fatalf("sync stderr = %q", f.errOut.String())
	}
}
