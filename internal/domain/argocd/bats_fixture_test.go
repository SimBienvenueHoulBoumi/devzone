package argocd

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// mgmtContext returns the services cluster context saved in the fixture state.
func mgmtContext(f *modFixture) string { return state.New(f.state).Get("cluster") }

// mgmtKubectl yields kubectl arguments with the fixture management context.
func mgmtKubectl(f *modFixture, args ...string) []string {
	return append([]string{"--context", mgmtContext(f)}, args...)
}

// devzoneKubectl yields kubectl arguments with the configured services context.
func devzoneKubectl(args ...string) []string {
	return append([]string{"--context", fexec.ContextName()}, args...)
}

// heldFixture prepares an installed Argo CD with a chart and a known revision
// so that a service can be held by the module instead of the helm-direct path.
func heldFixture(t *testing.T, svc string) *modFixture {
	t.Helper()
	f := newModFixture(t)
	f.markInstalled(t)
	writeChart(t, f.root, svc, "devzone-"+svc)
	writeTestFile(t, filepath.Join(f.root, "package.json"), "{\"version\": \"1.2.3\"}\n")
	return f
}

// writeChart writes a Chart.yaml with the given chart name in the code tree.
func writeChart(t *testing.T, root, svc, name string) {
	t.Helper()
	dir := filepath.Join(root, "charts", "devzone-"+svc)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(dir, "Chart.yaml"), "name: "+name+"\n")
}

// writeTestFile writes a text file in a temporary directory of a test.
func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// allowKubectl makes any unprogrammed kubectl call succeed with empty output.
func allowKubectl(f *modFixture) {
	f.r.On("kubectl", nil, fexec.Result{})
}

// callIndex returns the position of a recorded command, or -1 when absent.
func callIndex(calls []fake.Call, name string, args ...string) int {
	for i, call := range calls {
		if call.Name != name || len(call.Args) != len(args) {
			continue
		}
		same := true
		for j := range args {
			if call.Args[j] != args[j] {
				same = false
				break
			}
		}
		if same {
			return i
		}
	}
	return -1
}

// hasCall reports whether a command with these exact arguments was recorded.
func hasCall(calls []fake.Call, name string, args ...string) bool {
	return callIndex(calls, name, args...) >= 0
}

// stdinOf returns the standard input recorded for a command, as text.
func stdinOf(t *testing.T, call fake.Call) string {
	t.Helper()
	if call.Opts.Stdin == nil {
		return ""
	}
	data, err := io.ReadAll(call.Opts.Stdin)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// stdinFor returns the standard input of the first matching command.
func stdinFor(t *testing.T, calls []fake.Call, name string, args ...string) string {
	t.Helper()
	i := callIndex(calls, name, args...)
	if i < 0 {
		t.Fatalf("no recorded call %s %v", name, args)
	}
	return stdinOf(t, calls[i])
}

// newFixtureModule builds the module used by the tests that call a method
// directly, with the same options as the command-level fixture.
func newFixtureModule(t *testing.T, f *modFixture) *module {
	t.Helper()
	m, err := newModule(context.Background(), f.opts(), &f.out, &f.err)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// findStdinCall returns the first matching command whose standard input
// contains needle, or -1 when no such command was recorded.
func findStdinCall(t *testing.T, calls []fake.Call, name, needle string, args ...string) int {
	t.Helper()
	for i, call := range calls {
		if callIndex([]fake.Call{call}, name, args...) != 0 {
			continue
		}
		if strings.Contains(stdinOf(t, call), needle) {
			return i
		}
	}
	return -1
}

// joinedArgs renders a recorded command for failure messages.
func joinedArgs(call fake.Call) string { return call.Name + " " + strings.Join(call.Args, " ") }
