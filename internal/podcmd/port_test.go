package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/relays"
)

// TestHandlesPort checks that the pod command is registered, not delegated.
func TestHandlesPort(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := Run([]string{"handles", "port"}, &out, &errOut); code != 0 {
		t.Fatalf("handles: code %d", code)
	}
}

// usePortFixture replaces the environment factory with fakes: no kubectl and
// no HTTP request can reach the network from these tests.
func usePortFixture(t *testing.T, state string, active map[int]bool) *fake.Runner {
	t.Helper()
	runner := fake.New()
	for port, yes := range active {
		if yes {
			runner.On("kubectl", []string{"get", "pods", "--all-namespaces", "-l",
				"devzone.instance=devzone,devzone.port=" + strconv.Itoa(port), "-o", "name"},
				fexec.Result{Stdout: []byte("pod/" + relays.RelayName("devzone", port) + "\n")})
		}
	}
	runner.On("kubectl", nil, fexec.Result{Code: 1})
	previous := newPortEnvironment
	newPortEnvironment = func(ctx *cli.Context) *relays.Env {
		return &relays.Env{
			State: state, Instance: "devzone", Runner: runner,
			Probe: func(int) bool { return false }, Out: ctx.Out, Err: ctx.Err,
		}
	}
	t.Cleanup(func() { newPortEnvironment = previous })
	return runner
}

// portState creates a disposable state file for a port command.
func portState(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".devzone.modules")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestPortCommandListAndClose checks the routing of list, --close and resume
// through the registered command, with the same output as ports.sh.
func TestPortCommandListAndClose(t *testing.T) {
	state := portState(t, "ports=8080\n")
	usePortFixture(t, state, map[int]bool{8080: true})
	var out, errOut bytes.Buffer
	if code := Run([]string{"port"}, &out, &errOut); code != 0 {
		t.Fatalf("list: code %d, err %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "8080  ● active  no application") {
		t.Fatalf("list out = %q", out.String())
	}
	out.Reset()
	if code := Run([]string{"port", "resume"}, &out, &errOut); code != 0 || out.String() != "8080 ●\n" {
		t.Fatalf("resume: code %d, out %q", code, out.String())
	}
	out.Reset()
	if code := Run([]string{"port", "--close", "8080"}, &out, &errOut); code != 0 {
		t.Fatalf("close: code %d, err %q", code, errOut.String())
	}
	if out.String() != "✔ relay closed: 8080\n" {
		t.Fatalf("close out = %q", out.String())
	}
	data, err := os.ReadFile(state)
	if err != nil || string(data) != "ports=\n" {
		t.Fatalf("state = %q, %v", data, err)
	}
}

// TestPortCommandJSON checks the output of the list --json routing.
func TestPortCommandJSON(t *testing.T) {
	state := portState(t, "ports=8080\n")
	usePortFixture(t, state, nil)
	var out, errOut bytes.Buffer
	if code := Run([]string{"port", "list", "--json"}, &out, &errOut); code != 0 {
		t.Fatalf("code %d, err %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"port":8080`) || !strings.Contains(out.String(), "aucune application") {
		t.Fatalf("json = %q", out.String())
	}
}

// TestPortCommandRefusals fixes the exit code and message of an invalid port
// and of a state file that cannot be written.
func TestPortCommandRefusals(t *testing.T) {
	state := portState(t, "ports=8080\n")
	usePortFixture(t, state, nil)
	var out, errOut bytes.Buffer
	if code := Run([]string{"port", "--close", "70000"}, &out, &errOut); code != 1 ||
		!strings.Contains(errOut.String(), "invalid port") {
		t.Fatalf("invalid: code %d, err %q", code, errOut.String())
	}
	blocked := filepath.Join(t.TempDir(), "blocked")
	if err := os.WriteFile(blocked, []byte("not a folder\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	usePortFixture(t, filepath.Join(blocked, ".devzone.modules"), nil)
	errOut.Reset()
	if code := Run([]string{"port", "close", "8080"}, &out, &errOut); code != 1 ||
		!strings.Contains(errOut.String(), "state not saved") {
		t.Fatalf("state failure: code %d, err %q", code, errOut.String())
	}
}

// TestHelpListsPort checks that both command listings still cite devzone port.
func TestHelpListsPort(t *testing.T) {
	for _, file := range []string{"../../.devcontainer/help.sh", "../../README.md"} {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), "devzone port [--close <n>]") {
			t.Fatalf("%s misses the port command", file)
		}
	}
}

// TestPortWithoutRoot refuses to write in the current folder when no state
// file and no devzone root can be resolved.
func TestPortWithoutRoot(t *testing.T) {
	t.Setenv("DEVZONE_STATE", "")
	t.Setenv("DEVZONE_ROOT", "")
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	previous := defaultScript
	defaultScript = filepath.Join(t.TempDir(), "absent")
	defer func() { defaultScript = previous }()
	var out, errOut bytes.Buffer
	if code := Run([]string{"port"}, &out, &errOut); code != 1 {
		t.Fatalf("code %d", code)
	}
}
