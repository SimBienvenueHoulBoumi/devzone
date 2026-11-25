package postgres

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDisableConfirmationAbort checks that Enter in a terminal keeps the
// module and deletes nothing, as in postgres.bats.
func TestDisableConfirmationAbort(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_INTERACTIVE", "1")
	writeState(t, "postgres=on", "cluster=kind-devzone")
	calls := filepath.Join(f.root, "calls")
	body := `
CALLS="$6"
devzone() { printf 'CALL %s\n' "$*" >>"$CALLS"; }
change_module off postgres
`
	out, code := shellServices(t, body, "\n", calls)
	if code != 0 || !strings.Contains(out, "Aborted: nothing was deleted.") {
		t.Fatalf("disable: code %d, output %q", code, out)
	}
	data, err := os.ReadFile(f.statePath)
	if err != nil || !strings.Contains(string(data), "postgres=on") {
		t.Fatalf("state = %q, err %v", data, err)
	}
	if _, err := os.Stat(calls); !os.IsNotExist(err) {
		t.Fatalf("a devzone command was run: %v", err)
	}
}

// TestClusterDisplayAndMove checks the display, the refusal without --yes
// outside a terminal and the move with --yes, with the same calls as the shell.
func TestClusterDisplayAndMove(t *testing.T) {
	f := newFixture(t)
	writeState(t, "")
	body := `change_cluster`
	out, code := shellServices(t, body, "")
	if code != 0 || !strings.Contains(out, "no cluster chosen") {
		t.Fatalf("display: code %d, output %q", code, out)
	}
	writeState(t, "postgres=on", "cluster=kind-devzone")
	out, code = shellServices(t, body, "")
	if code != 0 || !strings.Contains(out, "kind-devzone (dedicated kind") {
		t.Fatalf("chosen cluster: code %d, output %q", code, out)
	}
	body = `
CALLS="$CALLS_PATH"
WANTED="$6"
cluster_choose() { printf '%s' "$WANTED"; }
account_remove() { :; }
account_admin() { printf 'ADMIN %s\n' "$*" >>"$CALLS"; }
cluster_release() { :; }
devzone_context_set() { :; }
devzone() { printf 'CALL %s\n' "$*" >>"$CALLS"; }
change_cluster "$WANTED" "${@:7}"
`
	calls := filepath.Join(f.root, "calls-no-yes")
	t.Setenv("CALLS_PATH", calls)
	out, code = shellServices(t, body, "", "host-cluster")
	if code != 1 || !strings.Contains(out, "not migrated") {
		t.Fatalf("without --yes: code %d, output %q", code, out)
	}
	calls = filepath.Join(f.root, "calls-yes")
	t.Setenv("CALLS_PATH", calls)
	out, code = shellServices(t, body, "", "host-cluster", "--yes")
	if code != 0 || !strings.Contains(out, "services cluster: host-cluster") {
		t.Fatalf("with --yes: code %d, output %q", code, out)
	}
	data, err := os.ReadFile(calls)
	if err != nil || !strings.Contains(string(data), "CALL postgres install") ||
		!strings.Contains(string(data), "ADMIN kind-devzone delete namespace devzone-postgres --wait=true") {
		t.Fatalf("calls = %q, err %v", data, err)
	}
	state, _ := os.ReadFile(f.statePath)
	if !strings.Contains(string(state), "cluster=host-cluster") {
		t.Fatalf("state = %q", state)
	}
}

// TestClusterDisabledAndSame checks that a disabled module only saves the
// choice and that choosing the current cluster changes nothing.
func TestClusterDisabledAndSame(t *testing.T) {
	f := newFixture(t)
	writeState(t, "")
	calls := filepath.Join(f.root, "calls")
	t.Setenv("CALLS_PATH", calls)
	body := `
CALLS="$CALLS_PATH"
WANTED="$6"
cluster_choose() { printf '%s' "$WANTED"; }
devzone_context_set() { :; }
devzone() { printf 'CALL %s\n' "$*" >>"$CALLS"; }
change_cluster "$WANTED"
`
	out, code := shellServices(t, body, "", "host-cluster")
	if code != 0 || !strings.Contains(out, "services cluster: host-cluster") {
		t.Fatalf("move: code %d, output %q", code, out)
	}
	data, err := os.ReadFile(f.statePath)
	if err != nil || !strings.Contains(string(data), "cluster=host-cluster") {
		t.Fatalf("state = %q, err %v", data, err)
	}
	if _, err := os.Stat(calls); !os.IsNotExist(err) {
		t.Fatalf("module reinstalled while disabled: %v", err)
	}
	out, code = shellServices(t, body, "", "host-cluster")
	if code != 0 || !strings.Contains(out, "already on host-cluster") {
		t.Fatalf("same cluster: code %d, output %q", code, out)
	}
}

// TestApplyRestartsRelay checks that apply restarts a stopped relay without
// reinstalling PostgreSQL, as postgres.bats did.
func TestApplyRestartsRelay(t *testing.T) {
	f := newFixture(t)
	writeState(t, "postgres=on", "cluster=kind-devzone")
	calls := filepath.Join(f.root, "calls")
	body := `
CALLS="$6"
devzone() {
    printf 'CALL %s\n' "$*" >>"$CALLS"
    case "$1 $2" in
        "postgres status") printf 'ready on kind-devzone, relay stopped: devzone apply\n' ;;
    esac
}
cluster_choose() { printf 'kind-devzone'; }
apply_postgres on
`
	out, code := shellServices(t, body, "", calls)
	if code != 0 || !strings.Contains(out, "relay restarted") {
		t.Fatalf("apply: code %d, output %q", code, out)
	}
	data, err := os.ReadFile(calls)
	if err != nil {
		t.Fatal(err)
	}
	want := "CALL postgres status\nCALL postgres relay-start\n"
	if string(data) != want {
		t.Fatalf("calls = %q, want %q", data, want)
	}
}
