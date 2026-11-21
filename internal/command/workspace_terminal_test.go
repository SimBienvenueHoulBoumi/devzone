package command

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// fakeShellKubectl puts a fake kubectl first in PATH: no context declared, and
// "exec -it" prints its arguments and exits with status. The real kubectl is never reached.
func fakeShellKubectl(t *testing.T, status int) {
	t.Helper()
	dir := t.TempDir()
	script := fmt.Sprintf("#!/bin/sh\n"+
		"case \"$*\" in\n"+
		"    *\"exec -it\"*) echo \"kubectl $*\"; exit %d ;;\n"+
		"esac\n"+
		"exit 0\n", status)
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestWorkspaceShellRunsInGo(t *testing.T) {
	requireBash(t)
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	// The entry point would print its arguments: the output must not show them
	entry(t, echoArgs+"\n")
	fakeShellKubectl(t, 0)
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "shell"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	want := "kubectl exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q from Go, not a delegation", out.String(), want)
	}
}

func TestWorkspaceShellKeepsKubectlStatus(t *testing.T) {
	requireBash(t)
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	fakeShellKubectl(t, 3)
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "shell"}, &out, &errOut); got != 3 {
		t.Fatalf("exit status = %d, want 3 (the status of kubectl)", got)
	}
}

func TestWorkspaceShellWithWordsIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\nexit 4\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "shell", "extra"}, &out, &errOut); got != 4 {
		t.Fatalf("exit status = %d, want 4 (propagated from bash)", got)
	}
	if out.String() != "args:[workspace][shell][extra]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestWorkspaceVSCodeRunsInGo(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "vscode"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if !strings.Contains(out.String(), "Pod not ready: devzone workspace status") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want the guide written by Go, not a delegation", out.String())
	}
}

func TestWorkspaceVSCodeWithWordsIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "vscode", "extra"}, &out, &errOut)
	if out.String() != "args:[workspace][vscode][extra]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}
