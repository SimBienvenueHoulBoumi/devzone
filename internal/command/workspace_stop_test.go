package command

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// fakeStopTools puts a fake kubectl and a fake helm first in PATH. The Argo CD
// namespace is absent unless argocd is true, and then the workspace Application
// exists too. helm prints its arguments. The real tools are never reached.
func fakeStopTools(t *testing.T, argocd bool) {
	t.Helper()
	dir := t.TempDir()
	namespace := "exit 1"
	application := "exit 1"
	if argocd {
		namespace = "exit 0"
		application = "exit 0"
	}
	kubectl := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"    \"config get-contexts -o name\") echo lab ;;\n" +
		"    *\"get namespace\"*) " + namespace + " ;;\n" +
		"    *\"get application\"*) " + application + " ;;\n" +
		"esac\n" +
		"exit 0\n"
	helm := "#!/bin/sh\necho \"helm $*\"\nexit 0\n"
	for name, script := range map[string]string{"kubectl": kubectl, "helm": helm} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", t.TempDir())
}

func skipWithoutUnix(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake tools are shell scripts")
	}
}

func TestWorkspaceStopRunsInGo(t *testing.T) {
	requireBash(t)
	skipWithoutUnix(t)
	// The entry point would print its arguments: the output must not show them
	entry(t, echoArgs+"\n")
	fakeStopTools(t, false)
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "stop"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	want := "helm uninstall devzone-workspace --namespace devzone-workspace\n"
	if out.String() != want || strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q, want %q from Go, not a delegation", out.String(), want)
	}
}

func TestWorkspaceStopWithWordsIsDelegated(t *testing.T) {
	requireBash(t)
	entry(t, echoArgs+"\nexit 4\n")
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "stop", "extra"}, &out, &errOut); got != 4 {
		t.Fatalf("exit status = %d, want 4 (propagated from bash)", got)
	}
	if out.String() != "args:[workspace][stop][extra]\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestWorkspaceStopWithArgocdIsDelegated(t *testing.T) {
	requireBash(t)
	skipWithoutUnix(t)
	entry(t, echoArgs+"\n")
	fakeStopTools(t, true)
	var out, errOut bytes.Buffer
	Run([]string{"workspace", "stop"}, &out, &errOut)
	if out.String() != "args:[workspace][stop]\n" {
		t.Fatalf("stdout = %q: want the Argo CD removal delegated to bash", out.String())
	}
}
