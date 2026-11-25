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

// TestEnableClusterRefused checks that an unknown or unreachable context is
// refused with code 2 and the exact message of cluster_choose.
func TestEnableClusterRefused(t *testing.T) {
	newFixture(t)
	script := filepath.Join(repoDevcontainer(t), "cluster.sh")
	body := `
cluster_candidates() { printf 'host-cluster\nkind-devzone\n'; }
cluster_is_local() { [ "$1" != kind-devzone ]; }
cluster_choose "$2"
`
	out, code := shellRun(t, script, body, "", "inconnu")
	if code != 2 || !strings.Contains(out, "unknown or unreachable cluster: inconnu") {
		t.Fatalf("unknown: code %d, output %q", code, out)
	}
	body = `
cluster_candidates() { printf 'kind-devzone\n'; }
cluster_choose host-cluster
`
	out, code = shellRun(t, script, body, "")
	if code != 2 {
		t.Fatalf("unreachable: code %d, output %q", code, out)
	}
}

// TestEnableWithoutKubernetesModule checks that without a visible host
// context only the dedicated kind can be chosen, so a host context is refused.
func TestEnableWithoutKubernetesModule(t *testing.T) {
	newFixture(t)
	script := filepath.Join(repoDevcontainer(t), "cluster.sh")
	body := `
cluster_candidates() { printf 'kind-devzone\n'; }
cluster_choose host-cluster
`
	out, code := shellRun(t, script, body, "")
	if code != 2 {
		t.Fatalf("host context without kubernetes module: code %d, output %q", code, out)
	}
}

// TestEnableMenuHostCluster checks the interactive menu: choice 1 selects the
// host cluster and the menu lists the two candidates.
func TestEnableMenuHostCluster(t *testing.T) {
	newFixture(t)
	t.Setenv("DEVZONE_INTERACTIVE", "1")
	script := filepath.Join(repoDevcontainer(t), "cluster.sh")
	body := `
cluster_candidates() { printf 'host-cluster\nkind-devzone\n'; }
cluster_menu
`
	out, code := shellRun(t, script, body, "1\n")
	if code != 0 || !strings.Contains(out, "1) host-cluster") ||
		!strings.Contains(out, "2) kind-devzone") {
		t.Fatalf("menu: code %d, output %q", code, out)
	}
	if !strings.HasSuffix(strings.TrimSpace(out), "host-cluster") {
		t.Fatalf("chosen cluster: %q", out)
	}
}

// TestEnableMenuEnterAndInvalid checks that Enter keeps the first candidate
// and that an out-of-list choice is refused, leaving the module disabled.
func TestEnableMenuEnterAndInvalid(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_INTERACTIVE", "1")
	script := filepath.Join(repoDevcontainer(t), "cluster.sh")
	body := `
cluster_candidates() { printf 'host-cluster\nkind-devzone\n'; }
cluster_menu
`
	out, code := shellRun(t, script, body, "\n")
	if code != 0 || !strings.HasSuffix(strings.TrimSpace(out), "host-cluster") {
		t.Fatalf("Enter: code %d, output %q", code, out)
	}
	out, code = shellRun(t, script, body, "9\n")
	if code != 2 || !strings.Contains(out, "invalid choice: 9") {
		t.Fatalf("invalid choice: code %d, output %q", code, out)
	}
	writeState(t, "cluster=kind-devzone")
	body = `
cluster_choose() { return 2; }
apply_postgres on
`
	out, code = shellServices(t, body, "")
	if code != 2 {
		t.Fatalf("apply after refusal: code %d, output %q", code, out)
	}
	if data, err := os.ReadFile(f.statePath); err != nil || !strings.Contains(string(data), "postgres=off") {
		t.Fatalf("state = %q, err %v", data, err)
	}
}

// TestEnableContextMismatch checks that a --context different from the saved
// cluster is refused with the devzone cluster hint and disables the module.
func TestEnableContextMismatch(t *testing.T) {
	f := newFixture(t)
	writeState(t, "cluster=kind-devzone")
	body := `
cluster_saved() { printf 'kind-devzone'; }
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
