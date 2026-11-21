package command

import (
	"bytes"
	"runtime"
	"strings"
	"testing"
)

// TestWorkspaceCopyToWithoutFolderIsDelegated: copy-to alone goes to bash, which
// gives the usage message
func TestWorkspaceCopyToWithoutFolderIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "copy-to"}, &out, &errOut)
	if out.String() != "args:[workspace][copy-to]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestWorkspaceCopyWithWordsIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "copy-to", "a", "b"}, &out, &errOut)
	Run([]string{"workspace", "copy-from", "a", "b"}, &out, &errOut)
	want := "args:[workspace][copy-to][a][b]\nargs:[workspace][copy-from][a][b]\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}

// TestWorkspaceCopyToMissingFolderRunsInGo: the folder check comes before any
// call to kubectl, so no fake cluster is needed
func TestWorkspaceCopyToMissingFolderRunsInGo(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "copy-to", "no-such-folder-754"}, &out, &errOut); got != 1 {
		t.Fatalf("exit status = %d, want 1 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(errOut.String(), "✖ folder not found: no-such-folder-754") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stderr = %q, stdout = %q: want the message from Go, not a delegation", errOut.String(), out.String())
	}
}

func TestWorkspaceCopyFromRunsInGo(t *testing.T) {
	requireBash(t)
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	entry(t, echoArgs+"\n")
	fakeKubectlOnPath(t)
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "copy-from", "mine"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want kubectl run by Go, not a delegation", out.String())
	}
}
