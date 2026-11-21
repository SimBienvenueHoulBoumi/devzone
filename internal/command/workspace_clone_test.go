package command

import (
	"bytes"
	"testing"
)

// TestWorkspaceCloneWithoutURLIsDelegated: clone alone goes to bash, which gives
// the usage message
func TestWorkspaceCloneWithoutURLIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "clone"}, &out, &errOut)
	if out.String() != "args:[workspace][clone]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

// TestWorkspaceCloneWithWordsIsDelegated: more than a url and a name goes to bash
func TestWorkspaceCloneWithWordsIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\n")
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "clone", "a", "b", "c"}, &out, &errOut)
	if want := "args:[workspace][clone][a][b][c]\n"; out.String() != want {
		t.Fatalf("stdout = %q, want %q", out.String(), want)
	}
}
