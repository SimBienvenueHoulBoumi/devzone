package command

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// fakeClusterReady fakes the preflight of workspace start so a routing test
// can run without a cluster, a fake kubectl or a real shell command.
func fakeClusterReady(t *testing.T) {
	t.Helper()
	oldReady, oldInstalled := commandKubeReady, commandArgoCDInstalled
	t.Cleanup(func() {
		commandKubeReady, commandArgoCDInstalled = oldReady, oldInstalled
	})
	commandKubeReady = func(workspace.Runner, bool) (string, bool) { return "", true }
	commandArgoCDInstalled = func(workspace.Runner) bool { return false }
}

// requireBash skips the test when bash cannot run the fake entry point
func requireBash(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("bash tests run on Unix only")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is not installed")
	}
}

// devzoneRootForAutoStart creates a temporary devzone folder so a test of a
// command can prove that the automatic start is reached from a devzone folder,
// without writing anything in the repository.
func devzoneRootForAutoStart(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "devzone")
	if err := os.MkdirAll(filepath.Join(root, ".devcontainer"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

// entry writes a fake bash entry point with the given body and points
// DEVZONE_BASH_ENTRY at it
func entry(t *testing.T, body string) {
	t.Helper()
	hostMode(t)
	path := filepath.Join(t.TempDir(), "devzone")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv(bashbridge.EnvVar, path)
}

// echoArgs prints the arguments, one bracketed group each
const echoArgs = `printf 'args:'; for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'`

func TestRunDelegatesUnknownCommand(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\nexit 3\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"unknown", "a b"}, &out, &errOut); got != 3 {
		t.Fatalf("exit status = %d, want 3 (propagated from bash)", got)
	}
	if out.String() != "args:[unknown][a b]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestRunWithoutArgumentsShowsHelp(t *testing.T) {
	hostMode(t)
	// The entry point of the fake package would print nothing: the help must
	// come from Go, not from a delegation
	setupPackage(t, "1.4.2")
	var out, errOut bytes.Buffer
	if got := Run(nil, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if out.String() != helpText("1.4.2") {
		t.Fatalf("stdout = %q, want the help text", out.String())
	}
}

func TestRunMissingEntryPoint(t *testing.T) {
	hostMode(t)
	t.Setenv(bashbridge.EnvVar, filepath.Join(t.TempDir(), "absent"))
	var errOut bytes.Buffer
	if got := Run([]string{"unknown"}, &bytes.Buffer{}, &errOut); got != 1 {
		t.Fatalf("exit status = %d, want 1", got)
	}
	if !strings.Contains(errOut.String(), "bash entry point not found") {
		t.Fatalf("stderr = %q, want the not found message", errOut.String())
	}
}

func TestRunPortedCommand(t *testing.T) {
	hostMode(t)
	var gotArgs []string
	Registry.Register(cli.Command{Name: "fake", Run: func(ctx *cli.Context) int {
		gotArgs = ctx.Args
		io.WriteString(ctx.Out, "handled\n")
		return 5
	}})
	t.Cleanup(func() {
		Registry = newDefaultRegistry()
	})
	// A missing entry point would fail a delegation: bash must not run here
	t.Setenv(bashbridge.EnvVar, filepath.Join(t.TempDir(), "absent"))
	var out bytes.Buffer
	if got := Run([]string{"fake", "x", "y"}, &out, &bytes.Buffer{}); got != 5 {
		t.Fatalf("exit status = %d, want 5 (from the handler)", got)
	}
	if strings.Join(gotArgs, "|") != "x|y" {
		t.Fatalf("handler args = %q, want x y", gotArgs)
	}
	if out.String() != "handled\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}
