package postgres

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestApplyRestartsRelay checks that apply restarts a stopped relay without
// reinstalling PostgreSQL, as postgres.bats did.
func TestApplyRestartsRelay(t *testing.T) {
	f := newFixture(t)
	writeState(t, "postgres=on", "cluster=kind-devzone")
	calls := filepath.Join(f.root, "calls")
	body := `
CALLS="$6"
devzone() {
    case "$1" in
        kube) return 0 ;;
    esac
    printf 'CALL %s\n' "$*" >>"$CALLS"
    case "$1 $2" in
        "postgres status") printf 'ready on kind-devzone, relay stopped: devzone apply\n' ;;
    esac
}
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
