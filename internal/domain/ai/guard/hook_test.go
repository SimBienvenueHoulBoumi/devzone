//go:build !windows

package guard

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// claudeHook is the fail-closed Claude Code hook. The program is passed as the
// first positional argument, so no path is ever interpolated into the command.
const claudeHook = `o=$("$1" ai guard claude --protocol 1); [ "$o" = "` + AllowLine + `" ] || { echo "devzone guard unavailable: command refused" >&2; exit 2; }`

// runHook executes the hook with program and one tool call, and returns its
// status and both output streams.
func runHook(t *testing.T, program, input string) (int, string, string) {
	t.Helper()
	cmd := exec.Command("bash", "-c", claudeHook, "devzone-hook", program)
	cmd.Stdin = strings.NewReader(input)
	cmd.Env = hookEnv()
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	if err == nil {
		return 0, out.String(), errOut.String()
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("run hook: %v", err)
	}
	return exitErr.ExitCode(), out.String(), errOut.String()
}

// hookEnv copies the test environment without host overrides or workspace
// paths, so the built program always evaluates the call on its own.
func hookEnv() []string {
	env := make([]string, 0, len(os.Environ()))
	for _, item := range os.Environ() {
		key := strings.SplitN(item, "=", 2)[0]
		if key == "DEVZONE_WORKSPACE" || key == "DEVZONE_ROOT" || strings.HasPrefix(key, "DEVZONE_ALLOW_") {
			continue
		}
		env = append(env, item)
	}
	return env
}

// writeProgram writes a tiny executable bash program in a temporary directory
// and returns its path. The scripts exist only for the lifetime of the test.
func writeProgram(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte("#!/usr/bin/env bash\n"+body), 0o755); err != nil {
		t.Fatalf("write program %s: %v", name, err)
	}
	return path
}
