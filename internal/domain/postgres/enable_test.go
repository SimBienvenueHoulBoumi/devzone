package postgres

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runDevzone runs the real entry point with the isolated environment of a test.
func runDevzone(t *testing.T, args ...string) (string, int) {
	t.Helper()
	command := osexec.Command("bash", append([]string{filepath.Join(repoDevcontainer(t), "devzone")}, args...)...)
	command.Stdin = strings.NewReader("")
	out, err := command.CombinedOutput()
	if err == nil {
		return string(out), 0
	}
	if exit, ok := err.(*osexec.ExitError); ok {
		return string(out), exit.ExitCode()
	}
	t.Fatalf("devzone: %v", err)
	return "", 1
}

// TestPostgresModuleKnownDisabled checks that the plain devzone summary lists
// postgres as optional with the enable command, as postgres.bats did.
func TestPostgresModuleKnownDisabled(t *testing.T) {
	newFixture(t)
	out, code := runDevzone(t)
	if code != 0 {
		t.Fatalf("devzone: code %d, output %q", code, out)
	}
	if !strings.Contains(out, "○ module postgres") || !strings.Contains(out, "devzone enable postgres") {
		t.Fatalf("summary %q misses postgres", out)
	}
}

// TestEnableContextMismatch checks that a --context different from the saved
// cluster is refused with the devzone cluster hint and disables the module.
func TestEnableContextMismatch(t *testing.T) {
	f := newFixture(t)
	writeState(t, "cluster=kind-devzone")
	body := `
devzone() { [ "$1 $2" = "kube saved" ] && printf 'kind-devzone'; }
apply_postgres on --context host-cluster
`
	out, code := shellServices(t, body, "")
	if code != 2 || !strings.Contains(out, "devzone cluster host-cluster") {
		t.Fatalf("mismatch: code %d, output %q", code, out)
	}
	if data, err := os.ReadFile(f.statePath); err != nil || !strings.Contains(string(data), "postgres=off") {
		t.Fatalf("state = %q, err %v", data, err)
	}
}
