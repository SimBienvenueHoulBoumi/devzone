//go:build !windows

package command

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// traceScript is a fake bash entry point that records its arguments in the file
// named by DEVZONE_TRACE and exits 0. A command that stays in Go never runs it,
// so the trace file is never created.
const traceScript = `#!/usr/bin/env bash
if [ -n "${DEVZONE_TRACE:-}" ]; then
    printf '%s\n' "$*" > "$DEVZONE_TRACE"
fi
exit 0
`

// tracePath returns a not-yet-existing file in a fresh temp dir and points
// DEVZONE_TRACE at it.
func tracePath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "trace")
	t.Setenv("DEVZONE_TRACE", path)
	return path
}

func TestPortedCommandsDoNotUseBash(t *testing.T) {
	// A ported command must run in Go: if it fell back to bash the trace
	// file would appear, so its absence proves the routing.
	requireBash(t)
	cases := []struct {
		name string
		args []string
	}{
		{"version", []string{"--version"}},
		{"help", []string{"help"}},
		{"workspace status", []string{"workspace", "status"}},
		{"workspace ports", []string{"workspace", "ports"}},
		{"workspace ports status", []string{"workspace", "ports", "status"}},
		{"workspace services", []string{"workspace", "services"}},
		{"workspace services status", []string{"workspace", "services", "status"}},
		{"workspace vscode", []string{"workspace", "vscode"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			trace := tracePath(t)
			entry(t, traceScript)
			fakeKubectlOnPath(t)
			t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", t.TempDir())
			var out, errOut bytes.Buffer
			Run(tc.args, &out, &errOut)
			if _, err := os.Stat(trace); err == nil {
				t.Fatalf("trace file %s exists: command %v went through bash", trace, tc.args)
			} else if !os.IsNotExist(err) {
				t.Fatalf("stat trace: %v", err)
			}
		})
	}
}

func TestOtherCommandsUseBash(t *testing.T) {
	// Witness: a command that is not ported must still go through bash, so the
	// trace file exists and holds its arguments. This keeps the detection from
	// being blind.
	requireBash(t)
	cases := []struct {
		name string
		args []string
	}{
		{"update", []string{"update"}},
		{"workspace ports demarrer", []string{"workspace", "ports", "demarrer"}},
		{"workspace ports status extra", []string{"workspace", "ports", "status", "extra"}},
		{"workspace services enable", []string{"workspace", "services", "enable"}},
		{"workspace services status extra", []string{"workspace", "services", "status", "extra"}},
		{"workspace nope", []string{"workspace", "nope"}},
		{"version extra", []string{"--version", "extra"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			trace := tracePath(t)
			entry(t, traceScript)
			fakeKubectlOnPath(t)
			t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", t.TempDir())
			var out, errOut bytes.Buffer
			Run(tc.args, &out, &errOut)
			data, err := os.ReadFile(trace)
			if err != nil {
				t.Fatalf("trace file missing: command %v did not go through bash", tc.args)
			}
			want := strings.Join(tc.args, " ")
			if !strings.Contains(string(data), want) {
				t.Fatalf("trace %q does not contain %q", string(data), want)
			}
		})
	}
}
