package podcmd

import (
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// withHandler registers h as the handler of name in the ported map, and removes it when the test ends.
func withHandler(t *testing.T, name string, h Handler) {
	t.Helper()
	ported[name] = h
	t.Cleanup(func() { delete(ported, name) })
}

// TestHandlesPortedAndUnknown checks the handles command: 0 for a ported command name, 1 otherwise.
func TestHandlesPortedAndUnknown(t *testing.T) {
	withHandler(t, "fake", func(args []string, out, errOut io.Writer) int { return 0 })
	if got := Run([]string{"handles", "fake"}, io.Discard, io.Discard); got != 0 {
		t.Fatalf("handles fake: got %v, want 0", got)
	}
	if got := Run([]string{"handles", "nope"}, io.Discard, io.Discard); got != 1 {
		t.Fatalf("handles nope: got %v, want 1", got)
	}
}

// TestHandlesUsage checks the usage error of the handles command.
func TestHandlesUsage(t *testing.T) {
	var errOut strings.Builder
	if got := Run([]string{"handles"}, io.Discard, &errOut); got != 2 {
		t.Fatalf("handles: got %v, want 2", got)
	}
	if !strings.Contains(errOut.String(), "usage:") {
		t.Fatalf("errOut = %q, want it to contain %q", errOut.String(), "usage:")
	}
}

// TestPortedCommandRuns checks that a ported command runs its handler with the arguments after the command name.
func TestPortedCommandRuns(t *testing.T) {
	var got []string
	var out strings.Builder
	withHandler(t, "fake", func(args []string, hout, _ io.Writer) int {
		got = args
		io.WriteString(hout, "ok")
		return 3
	})
	if rc := Run([]string{"fake", "a", "b"}, &out, io.Discard); rc != 3 {
		t.Fatalf("fake a b: got %v, want 3", rc)
	}
	if !strings.Contains(out.String(), "ok") {
		t.Fatalf("out = %q, want it to contain %q", out.String(), "ok")
	}
	if joined := strings.Join(got, ","); joined != "a,b" {
		t.Fatalf("got = %q, want %q", joined, "a,b")
	}
}

// TestUnknownCommandDelegatesToShell checks that an unknown command is delegated to the pod shell entry point.
func TestUnknownCommandDelegatesToShell(t *testing.T) {
	script := filepath.Join(t.TempDir(), "script")
	err := os.WriteFile(script, []byte("#!/usr/bin/env bash\necho \"args:$*\"\necho \"from:${DEVZONE_FROM_GO:-}\"\nexit 7\n"), 0o755)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_POD_SCRIPT", script)
	var out strings.Builder
	if rc := Run([]string{"zzz", "a", "b"}, &out, io.Discard); rc != 7 {
		t.Fatalf("zzz a b: got %v, want 7", rc)
	}
	if !strings.Contains(out.String(), "args:zzz a b") {
		t.Fatalf("out = %q, want it to contain %q", out.String(), "args:zzz a b")
	}
	if !strings.Contains(out.String(), "from:1") {
		t.Fatalf("out = %q, want it to contain %q", out.String(), "from:1")
	}
}

// TestDelegateWithoutScript checks the 127 result when no pod shell entry point is found.
func TestDelegateWithoutScript(t *testing.T) {
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	old := defaultScript
	defaultScript = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { defaultScript = old })
	var errOut strings.Builder
	if rc := Run([]string{"unknown"}, io.Discard, &errOut); rc != 127 {
		t.Fatalf("unknown: got %v, want 127", rc)
	}
	if !strings.Contains(errOut.String(), "not found") {
		t.Fatalf("errOut = %q, want it to contain %q", errOut.String(), "not found")
	}
}

// TestPortedIsSorted checks that Ported returns the names of the ported commands sorted.
func TestPortedIsSorted(t *testing.T) {
	withHandler(t, "zeta", func(args []string, out, errOut io.Writer) int { return 0 })
	withHandler(t, "alpha", func(args []string, out, errOut io.Writer) int { return 0 })
	got := Ported()
	if !sort.StringsAreSorted(got) {
		t.Fatalf("Ported is not sorted: %v", got)
	}
	joined := "," + strings.Join(got, ",") + ","
	for _, want := range []string{"alpha", "zeta", "--version"} {
		if !strings.Contains(joined, ","+want+",") {
			t.Fatalf("Ported misses %q: %v", want, got)
		}
	}
}
