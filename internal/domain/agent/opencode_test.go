package agent

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

// captureCoreStarter records the session command instead of starting a process.
type captureCoreStarter struct {
	cmd SessionCmd
}

// Start records cmd and returns an already exited process.
func (s *captureCoreStarter) Start(cmd SessionCmd) (SessionProcess, error) {
	s.cmd = cmd
	return frozenProcess{}, nil
}

// silentRunner records calls without running any program.
type silentRunner struct {
	calls []string
}

// Run records the call and returns an empty successful result.
func (r *silentRunner) Run(ctx context.Context, name string, args []string, opts Opts) (Result, error) {
	r.calls = append(r.calls, name+" "+strings.Join(args, " "))
	return Result{}, nil
}

// TestOpenCodeLaunchDisablesCoreDumps checks that the injected shell sets the
// core limit before replacing itself with opencode, without a fake PATH binary.
func TestOpenCodeLaunchDisablesCoreDumps(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	dir := t.TempDir()
	brief := filepath.Join(dir, "brief.md")
	writeFileT(t, brief, "brief\n")
	shell := filepath.Join(dir, "bash")
	look := func(name string) (string, error) {
		if name != "bash" {
			return "", errors.New("not found: " + name)
		}
		return shell, nil
	}
	runner := &silentRunner{}
	starter := &captureCoreStarter{}
	_, err := OpenCodeLaunch(context.Background(), runner, look, starter,
		dir, "big-pickle", brief, filepath.Join(dir, "journal.log"),
		filepath.Join(dir, "state"), LocalModel{})
	if err != nil {
		t.Fatal(err)
	}
	got := starter.cmd
	if got.Name != shell {
		t.Fatalf("shell = %q, want %q", got.Name, shell)
	}
	if len(got.Args) < 5 || got.Args[0] != "-c" || !strings.Contains(got.Args[1], "ulimit -c 0") || !strings.Contains(got.Args[1], `exec "$@"`) {
		t.Fatalf("no core limit wrapper: %q", got.Args)
	}
	if got.Args[2] != "opencode" || got.Args[3] != "opencode" || !strings.Contains(strings.Join(got.Args, " "), "opencode/big-pickle") {
		t.Fatalf("wrapped opencode args: %q", got.Args)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("unexpected runner calls: %q", runner.calls)
	}
}

// TestOpenCodeLaunchWithoutShellKeepsDirectCommand checks the fallback when no
// shell can be found: the session still starts, without a wrapper.
func TestOpenCodeLaunchWithoutShellKeepsDirectCommand(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	dir := t.TempDir()
	brief := filepath.Join(dir, "brief.md")
	writeFileT(t, brief, "brief\n")
	look := func(string) (string, error) { return "", errors.New("no shell") }
	starter := &captureCoreStarter{}
	_, err := OpenCodeLaunch(context.Background(), nil, look, starter,
		dir, "big-pickle", brief, filepath.Join(dir, "journal.log"),
		filepath.Join(dir, "state"), LocalModel{})
	if err != nil {
		t.Fatal(err)
	}
	if starter.cmd.Name != "opencode" || len(starter.cmd.Args) == 0 || starter.cmd.Args[0] != "run" {
		t.Fatalf("direct command lost: %q %q", starter.cmd.Name, starter.cmd.Args)
	}
}
