package command

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// fakeKubectlOnPath puts a fake kubectl first in PATH: the pod listed, no legacy
// copies, no context declared. The real kubectl is never reached.
func fakeKubectlOnPath(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"    *\"get pods\"*) echo 'devzone-workspace-0  1/1  Running' ;;\n" +
		"    *exec*) cat >/dev/null ;;\n" +
		"esac\n" +
		"exit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestWorkspaceStatusRunsInGo(t *testing.T) {
	requireBash(t)
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	// The entry point would print its arguments: the output must not show them
	entry(t, echoArgs+"\n")
	fakeKubectlOnPath(t)
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "status"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(out.String(), "devzone-workspace-0") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want the pod listed by Go, not a delegation", out.String())
	}
}

func TestWorkspaceStatusWithWordsIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\nexit 4\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "status", "extra"}, &out, &errOut); got != 4 {
		t.Fatalf("exit status = %d, want 4 (propagated from bash)", got)
	}
	if out.String() != "args:[workspace][status][extra]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestWorkspaceAloneIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if out.String() != "args:[workspace]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestWorkspaceOtherSubcommandIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "nope", "x"}, &out, &errOut)
	if out.String() != "args:[workspace][nope][x]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

// TestWorkspaceStartEnablesWatcher checks that a successful cluster start
// triggers the single automatic-start function and that a failed one does not.
func TestWorkspaceStartEnablesWatcher(t *testing.T) {
	requireBash(t)
	t.Setenv("DEVZONE_ROOT", devzoneRootForAutoStart(t))
	calls := 0
	previous := commandEnsureAutoStart
	commandEnsureAutoStart = func(out, _ io.Writer) {
		calls++
		fmt.Fprintln(out, "✔ port watcher: automatic start enabled")
	}
	t.Cleanup(func() { commandEnsureAutoStart = previous })
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "start", "--image", "x:1"}, &out, &errOut); got != 0 {
		t.Fatalf("status = %d, err = %q", got, errOut.String())
	}
	want := "args:[workspace][start][--image][x:1]\n✔ port watcher: automatic start enabled\n"
	if out.String() != want || calls != 1 {
		t.Fatalf("stdout = %q, enable calls = %d, want %q and 1", out.String(), calls, want)
	}
	entry(t, echoArgs+"\nexit 4\n")
	out.Reset()
	errOut.Reset()
	if got := Run([]string{"workspace", "start"}, &out, &errOut); got != 4 {
		t.Fatalf("failed start status = %d, want 4", got)
	}
	if calls != 1 || strings.Contains(out.String(), "automatic start") {
		t.Fatalf("failed start enabled the watcher: calls = %d, out = %q", calls, out.String())
	}
}
