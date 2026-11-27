package command

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestPortsAutomaticStartRouting checks that enable, disable and the internal
// agent run in Go, never in the shell entry point.
func TestPortsAutomaticStartRouting(t *testing.T) {
	var calls []string
	oldEnable, oldDisable, oldAgent := commandPortsEnable, commandPortsDisable, commandPortsAgent
	t.Cleanup(func() {
		commandPortsEnable, commandPortsDisable, commandPortsAgent = oldEnable, oldDisable, oldAgent
	})
	record := func(name string) func(io.Writer, io.Writer) int {
		return func(out, _ io.Writer) int {
			calls = append(calls, name)
			return 0
		}
	}
	commandPortsEnable = record("enable")
	commandPortsDisable = record("disable")
	commandPortsAgent = record("agent")
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"workspace", "ports", "enable"}, "enable"},
		{[]string{"workspace", "ports", "disable"}, "disable"},
		{[]string{"workspace", "ports", "agent"}, "agent"},
	} {
		var out, errOut bytes.Buffer
		if got := Run(tc.args, &out, &errOut); got != 0 {
			t.Fatalf("%v: status = %d, err = %q", tc.args, got, errOut.String())
		}
		if len(calls) != 1 || calls[0] != tc.want {
			t.Fatalf("%v: calls = %v, want %q", tc.args, calls, tc.want)
		}
		calls = nil
	}
}

// TestUninstallWithoutObjectsStillDisables keeps the retirement when the
// cluster has no object to remove.
func TestUninstallWithoutObjectsStillDisables(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	registerLists(t, runner, "kind-devzone-ci", "", "", "")
	chdir(t, root)
	calls := 0
	commandPortsDisable = func(io.Writer, io.Writer) int {
		calls++
		return 0
	}
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 || calls != 1 {
		t.Fatalf("code = %d, calls = %d, err = %q", code, calls, errOut.String())
	}
}

// TestUninstallDisablesAutomaticStart checks that uninstall retires the
// automatic start, and returns its status when the retirement fails.
func TestUninstallDisablesAutomaticStart(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		want   int
	}{{"success", 0, 0}, {"failure", 3, 3}} {
		t.Run(tc.name, func(t *testing.T) {
			root := devzoneDir(t, "cluster=kind-devzone-ci")
			runner := fake.New()
			registerHostProbe(t, runner, root)
			registerLists(t, runner, "kind-devzone-ci", "devzone-workspace\n", "", "")
			runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-workspace", "--ignore-not-found"}, exec.Result{})
			chdir(t, root)
			calls := 0
			commandPortsDisable = func(out, _ io.Writer) int {
				calls++
				if tc.status != 0 {
					io.WriteString(out, "✖ automatic start not disabled\n")
				}
				return tc.status
			}
			var out, errOut bytes.Buffer
			code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
			if code != tc.want || calls != 1 {
				t.Fatalf("code = %d, calls = %d, want %d and 1 (err %q)", code, calls, tc.want, errOut.String())
			}
		})
	}
}
