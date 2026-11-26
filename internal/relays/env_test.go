package relays

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// envFixture builds a relays environment with a fake kubectl and fake probes.
func envFixture(t *testing.T, state string, active, answering map[int]bool) (*Env, *fake.Runner, *bytes.Buffer) {
	t.Helper()
	runner := fake.New()
	for port, yes := range active {
		label := "devzone.instance=devzone,devzone.port=" + strconv.Itoa(port)
		if yes {
			runner.On("kubectl", []string{"get", "pods", "--all-namespaces", "-l", label, "-o", "name"},
				fexec.Result{Stdout: []byte("pod/" + RelayName("devzone", port) + "\n")})
		}
		runner.On("kubectl", []string{"delete", "pod", "--all-namespaces", "-l", label, "--ignore-not-found"}, fexec.Result{})
	}
	runner.On("kubectl", nil, fexec.Result{Code: 1})
	out := &bytes.Buffer{}
	env := &Env{
		State: state, Instance: "devzone", Runner: runner,
		Probe: func(port int) bool { return answering[port] },
		Out:   out, Err: &bytes.Buffer{},
	}
	return env, runner, out
}

// TestListSortedWithActivity checks the exact list lines of the former
// ports.bats test: sorted ports, active marks and the application behind them.
func TestListSortedWithActivity(t *testing.T) {
	state := writeState(t, t.TempDir(), "ports=8080,3000,3000\n")
	env, runner, out := envFixture(t, state, map[int]bool{8080: true}, map[int]bool{8080: true})
	if err := env.List(); err != nil {
		t.Fatal(err)
	}
	want := "  3000  ○ stopped  no application\n  8080  ● active  application responds\n"
	if out.String() != want {
		t.Fatalf("list = %q, want %q", out.String(), want)
	}
	calls := runner.Calls()
	if len(calls) != 2 {
		t.Fatalf("kubectl calls = %v", calls)
	}
	labels := 0
	for _, call := range calls {
		if call.Name != "kubectl" {
			t.Fatalf("unexpected command: %s", call.Name)
		}
		for _, arg := range call.Args {
			if strings.HasPrefix(arg, "devzone.instance=devzone,devzone.port=") {
				labels++
			}
		}
	}
	if labels != 2 {
		t.Fatalf("relay labels = %d, calls %v", labels, calls)
	}
}

// TestListNoRelay checks the empty state line.
func TestListNoRelay(t *testing.T) {
	env, _, out := envFixture(t, writeState(t, t.TempDir(), ""), nil, nil)
	if err := env.List(); err != nil {
		t.Fatal(err)
	}
	if out.String() != "no relay\n" {
		t.Fatalf("list = %q", out.String())
	}
}

// TestJSONFixesKeysAndFrenchValues checks the machine-readable contract read
// by devzone status --json.
func TestJSONFixesKeysAndFrenchValues(t *testing.T) {
	state := writeState(t, t.TempDir(), "ports=8080\n")
	env, _, out := envFixture(t, state, map[int]bool{8080: true}, map[int]bool{8080: true})
	if err := env.JSON(); err != nil {
		t.Fatal(err)
	}
	want := `[{"port":8080,"active":true,"application":"application répond","auto":false}]` + "\n"
	if out.String() != want {
		t.Fatalf("json = %q, want %q", out.String(), want)
	}
	env, _, out = envFixture(t, state, nil, nil)
	if err := env.JSON(); err != nil {
		t.Fatal(err)
	}
	want = `[{"port":8080,"active":false,"application":"aucune application","auto":false}]` + "\n"
	if out.String() != want {
		t.Fatalf("json = %q, want %q", out.String(), want)
	}
}

// TestCloseRemovesRelayAndState checks that closing one port keeps the others
// and that kubectl is called through the injected runner only.
func TestCloseRemovesRelayAndState(t *testing.T) {
	state := writeState(t, t.TempDir(), "ports=3000,8080\n")
	env, runner, out := envFixture(t, state, map[int]bool{3000: true, 8080: true}, nil)
	if err := env.Close(8080); err != nil {
		t.Fatal(err)
	}
	if out.String() != "✔ relay closed: 8080\n" {
		t.Fatalf("out = %q", out.String())
	}
	if got, want := PortList(state), []int{3000}; len(got) != 1 || got[0] != want[0] {
		t.Fatalf("state = %v", got)
	}
	found := false
	for _, call := range runner.Calls() {
		if call.Name != "kubectl" {
			t.Fatalf("unexpected command: %s", call.Name)
		}
		if len(call.Args) > 0 && call.Args[0] == "delete" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no relay deletion: %v", runner.Calls())
	}
}

// TestCloseStateFailureIsReported checks that a state write failure leaves no
// success line on the output.
func TestCloseStateFailureIsReported(t *testing.T) {
	dir := t.TempDir()
	blocked := filepath.Join(dir, "blocked")
	if err := os.WriteFile(blocked, []byte("not a folder\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	env, _, out := envFixture(t, filepath.Join(blocked, ".devzone.modules"), nil, nil)
	if err := env.Close(8080); err == nil {
		t.Fatal("expected a state failure")
	}
	if out.Len() != 0 {
		t.Fatalf("success printed on a failure: %q", out.String())
	}
}

// TestSummaryRecap checks the one-line recap used by the devzone status.
func TestSummaryRecap(t *testing.T) {
	state := writeState(t, t.TempDir(), "ports=8080\n")
	env, _, out := envFixture(t, state, map[int]bool{8080: true}, nil)
	if err := env.Summary(); err != nil {
		t.Fatal(err)
	}
	if out.String() != "8080 ●\n" {
		t.Fatalf("summary = %q", out.String())
	}
	env, _, out = envFixture(t, writeState(t, t.TempDir(), ""), nil, nil)
	if err := env.Summary(); err != nil {
		t.Fatal(err)
	}
	if out.String() != "none\n" {
		t.Fatalf("summary = %q", out.String())
	}
}
