package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// noShell makes the shell fallback unavailable, so a command that is not ported fails instead of being answered by the shell of the pod running the test.
func noShell(t *testing.T) {
	t.Helper()
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	old := defaultScript
	defaultScript = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { defaultScript = old })
}

// runVersion runs a pod command with buffers and returns its standard output, its error output and its exit code.
func runVersion(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(args, &out, &errOut)
	return out.String(), errOut.String(), code
}

// TestVersionLong checks that --version prints the version from DEVZONE_VERSION.
func TestVersionLong(t *testing.T) {
	noShell(t)
	t.Setenv("DEVZONE_VERSION", "1.2.3")
	out, errOut, code := runVersion(t, "--version")
	want := 0
	if got := code; got != want {
		t.Fatalf("code = %v, want %v", got, want)
	}
	wantOut := "devzone 1.2.3\n"
	if got := out; got != wantOut {
		t.Fatalf("out = %q, want %q", got, wantOut)
	}
	if errOut != "" {
		t.Fatalf("errOut = %q, want empty", errOut)
	}
}

// TestVersionShort checks that -v prints the same version as --version.
func TestVersionShort(t *testing.T) {
	noShell(t)
	t.Setenv("DEVZONE_VERSION", "4.5.6")
	out, errOut, code := runVersion(t, "-v")
	want := 0
	if got := code; got != want {
		t.Fatalf("code = %v, want %v", got, want)
	}
	wantOut := "devzone 4.5.6\n"
	if got := out; got != wantOut {
		t.Fatalf("out = %q, want %q", got, wantOut)
	}
	if errOut != "" {
		t.Fatalf("errOut = %q, want empty", errOut)
	}
}

// TestVersionUnknown checks that an empty or unset version is reported as unknown.
func TestVersionUnknown(t *testing.T) {
	noShell(t)
	t.Setenv("DEVZONE_VERSION", "")
	out, errOut, code := runVersion(t, "--version")
	want := 0
	if got := code; got != want {
		t.Fatalf("code = %v, want %v", got, want)
	}
	wantOut := "devzone unknown\n"
	if got := out; got != wantOut {
		t.Fatalf("out = %q, want %q", got, wantOut)
	}
	if errOut != "" {
		t.Fatalf("errOut = %q, want empty", errOut)
	}

	t.Setenv("DEVZONE_VERSION", "x")
	if err := os.Unsetenv("DEVZONE_VERSION"); err != nil {
		t.Fatal(err)
	}
	out, errOut, code = runVersion(t, "--version")
	if got := code; got != 0 {
		t.Fatalf("code = %v, want 0", got)
	}
	if got := out; got != wantOut {
		t.Fatalf("out = %q, want %q", got, wantOut)
	}
	if errOut != "" {
		t.Fatalf("errOut = %q, want empty", errOut)
	}
}

// TestVersionIgnoresArguments checks that extra arguments do not change the version output.
func TestVersionIgnoresArguments(t *testing.T) {
	noShell(t)
	t.Setenv("DEVZONE_VERSION", "7.8.9")
	out, errOut, code := runVersion(t, "--version", "extra", "words")
	want := 0
	if got := code; got != want {
		t.Fatalf("code = %v, want %v", got, want)
	}
	wantOut := "devzone 7.8.9\n"
	if got := out; got != wantOut {
		t.Fatalf("out = %q, want %q", got, wantOut)
	}
	if errOut != "" {
		t.Fatalf("errOut = %q, want empty", errOut)
	}
}
