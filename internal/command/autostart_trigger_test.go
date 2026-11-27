package command

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// TestAutoStartExcludedCommands lists the commands that never install anything:
// read-only help and version, the two refusals, and stop, which must keep its
// effect until the next start or session.
func TestAutoStartExcludedCommands(t *testing.T) {
	cases := []struct {
		name string
		args []string
		skip bool
	}{
		{"help", []string{"help"}, true},
		{"no argument", nil, true},
		{"version", []string{"--version"}, true},
		{"uninstall", []string{"uninstall"}, true},
		{"ports disable", []string{"workspace", "ports", "disable"}, true},
		{"ports stop", []string{"workspace", "ports", "stop"}, true},
		{"workspace stop", []string{"workspace", "stop"}, true},
		{"watcher loop", []string{"workspace", "ports", "loop"}, true},
		{"watcher agent", []string{"workspace", "ports", "agent"}, true},
		{"update", []string{"update"}, false},
		{"workspace command", []string{"workspace", "ports", "status"}, false},
		{"workspace start", []string{"workspace", "start"}, false},
		{"folder creation", []string{"new-devzone"}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := autoStartExcluded(tc.args); got != tc.skip {
				t.Fatalf("excluded = %v, want %v for %v", got, tc.skip, tc.args)
			}
		})
	}
}

// TestAutoStartTriggersOnCreateUpdateAndCommand checks that one user command,
// an update and the creation of a folder all reach the single ensure function,
// with the new folder as the devzone folder for a creation.
func TestAutoStartTriggersOnCreateUpdateAndCommand(t *testing.T) {
	requireBash(t)
	root := t.TempDir()
	current := filepath.Join(root, "current")
	if err := os.MkdirAll(filepath.Join(current, ".devcontainer"), 0o755); err != nil {
		t.Fatal(err)
	}
	created := filepath.Join(root, "created")
	creationScript := "mkdir -p \"$1/.devcontainer\"\n"
	cases := []struct {
		name       string
		args       []string
		body       string
		wantFolder string
	}{
		{"update", []string{"update"}, "exit 0\n", current},
		{"command", []string{"workspace", "ports", "restart"}, "exit 0\n", current},
		{"creation", []string{created}, creationScript, created},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			previous := commandEnsureAutoStart
			calls, folder := 0, ""
			commandEnsureAutoStart = func(io.Writer, io.Writer) {
				calls++
				folder = os.Getenv("DEVZONE_ROOT")
			}
			t.Cleanup(func() { commandEnsureAutoStart = previous })
			entry(t, tc.body)
			// update is ported to Go: it works on the folder of the working directory
			t.Chdir(current)
			t.Setenv("DEVZONE_ROOT", current)
			var out, errOut bytes.Buffer
			if code := Run(tc.args, &out, &errOut); code != 0 {
				t.Fatalf("status = %d, err = %q", code, errOut.String())
			}
			if calls != 1 || folder != tc.wantFolder {
				t.Fatalf("ensure calls = %d, folder = %q, want 1 and %q", calls, folder, tc.wantFolder)
			}
			if os.Getenv("DEVZONE_ROOT") != current {
				t.Fatalf("DEVZONE_ROOT was not restored: %q", os.Getenv("DEVZONE_ROOT"))
			}
		})
	}
}

// TestAutoStartNotTriggeredByFailedCommand keeps a failed command from
// installing anything, as a failed workspace start must not install a watcher.
func TestAutoStartNotTriggeredByFailedCommand(t *testing.T) {
	requireBash(t)
	previous := commandEnsureAutoStart
	calls := 0
	commandEnsureAutoStart = func(io.Writer, io.Writer) { calls++ }
	t.Cleanup(func() { commandEnsureAutoStart = previous })
	entry(t, "exit 4\n")
	t.Setenv("DEVZONE_ROOT", t.TempDir())
	if code := Run([]string{"ai"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 4 {
		t.Fatalf("status = %d, want 4", code)
	}
	if calls != 0 {
		t.Fatalf("ensure called %d times after a failed command", calls)
	}
}

// TestPortsCommandsMemoriseAndClearRefusal checks that disable writes the
// refusal in this devzone folder and enable clears it, with no real watcher.
func TestPortsCommandsMemoriseAndClearRefusal(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".devcontainer"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", t.TempDir())
	t.Setenv("DEVZONE_ROOT", root)
	oldEnable, oldDisable, oldEnsure := commandPortsEnable, commandPortsDisable, commandEnsureAutoStart
	t.Cleanup(func() {
		commandPortsEnable, commandPortsDisable, commandEnsureAutoStart = oldEnable, oldDisable, oldEnsure
	})
	commandEnsureAutoStart = func(io.Writer, io.Writer) {}
	commandPortsDisable = func(io.Writer, io.Writer) int { return 0 }
	commandPortsEnable = func(io.Writer, io.Writer) int { return 0 }
	if code := Run([]string{"workspace", "ports", "disable"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 0 {
		t.Fatalf("disable status = %d", code)
	}
	if !workspace.PortsRefused() {
		t.Fatal("ports disable did not memorise the refusal")
	}
	if code := Run([]string{"workspace", "ports", "enable"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 0 {
		t.Fatalf("enable status = %d", code)
	}
	if workspace.PortsRefused() {
		t.Fatal("ports enable did not clear the refusal")
	}
}

// TestUninstallMemorisesRefusal checks that removing a devzone also records the
// refusal in the folder that was removed, with fake kubectl answers only.
func TestUninstallMemorisesRefusal(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "", "", "")
	chdir(t, root)
	t.Setenv("PWD", root)
	t.Setenv("HOME", t.TempDir())
	var out, errOut bytes.Buffer
	ctx := &cli.Context{
		Args: []string{"--yes"}, Out: &out, Err: &errOut, Runner: runner,
	}
	code := uninstallCommand(ctx)
	if code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if !workspace.PortsRefused() {
		t.Fatal("uninstall did not memorise the refusal")
	}
}
