//go:build !windows

package guard

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestClaudeHookFailsClosedOnUnusablePrograms checks that an old program, a
// missing program, empty output, odd statuses and altered lines all refuse a
// permitted call because the exact announcement is never read.
func TestClaudeHookFailsClosedOnUnusablePrograms(t *testing.T) {
	allowed := callInput(t, "claude", "kubectl get pods")
	refusal := "devzone guard unavailable: command refused"

	missing := filepath.Join(t.TempDir(), "no-such-program")
	code, _, errOut := runHook(t, missing, allowed)
	if code != 2 || !strings.Contains(errOut, refusal) {
		t.Fatalf("missing program: code %d, stderr %q; want 2 and the refusal", code, errOut)
	}

	programs := []struct {
		name string
		body string
	}{
		{"old", "printf '%s\\n' 'model one' 'model two'\nexit 0\n"},
		{"empty", "exit 0\n"},
		{"status 1", "exit 1\n"},
		{"status 3", "exit 3\n"},
		{"status 127", "exit 127\n"},
		{"trailing space", "printf '%s\\n' '" + AllowLine + " '\nexit 0\n"},
		{"extra text", "printf '%s\\n' '" + AllowLine + " extra'\nexit 0\n"},
		{"extra line", "printf '%s\\n' '" + AllowLine + "' 'unexpected'\nexit 0\n"},
	}
	for _, tc := range programs {
		t.Run(tc.name, func(t *testing.T) {
			program := writeProgram(t, strings.ReplaceAll(tc.name, " ", "-"), tc.body)
			code, out, errOut := runHook(t, program, allowed)
			if code != 2 || out != "" || !strings.Contains(errOut, refusal) {
				t.Fatalf("code %d, stdout %q, stderr %q; want 2, no stdout and the refusal",
					code, out, errOut)
			}
		})
	}
}

// TestClaudeHookWithBuiltPod checks the hook end to end against the program
// built from the pod entry point: only an announced allowed call passes.
func TestClaudeHookWithBuiltPod(t *testing.T) {
	program := buildPodProgram(t)
	forbidden := "\x64\x6f\x63\x6b\x65\x72" + " ps"
	refusal := "devzone guard unavailable: command refused"
	cases := []struct {
		name string
		cmd  string
		code int
	}{
		{"forbidden", forbidden, 2},
		{"allowed", "kubectl get pods", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			code, out, errOut := runHook(t, program, callInput(t, "claude", tc.cmd))
			if code != tc.code || out != "" {
				t.Fatalf("code %d, stdout %q; want %d and no stdout", code, out, tc.code)
			}
			if tc.code == 2 && !strings.Contains(errOut, refusal) {
				t.Fatalf("stderr %q does not contain the hook refusal", errOut)
			}
			if tc.code == 0 && errOut != "" {
				t.Fatalf("allowed call wrote stderr %q", errOut)
			}
		})
	}
}

// buildPodProgram builds the pod CLI into a temporary directory for the hook
// test, without depending on a program installed in the environment.
func buildPodProgram(t *testing.T) string {
	t.Helper()
	program := filepath.Join(t.TempDir(), "devzone-pod")
	build := exec.Command("go", "build", "-o", program, "../../../../cmd/devzone-pod")
	build.Env = hookEnv()
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build pod program: %v\n%s", err, output)
	}
	return program
}
