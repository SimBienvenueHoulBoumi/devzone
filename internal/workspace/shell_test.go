package workspace

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// shellExec is the joined arguments of the kubectl exec of Shell, without the context
const shellExec = "exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash"

// runShell runs Shell on r with stdin, and returns its status, standard output and error
func runShell(r Runner, stdin string) (int, string, string) {
	var out, errOut bytes.Buffer
	status := Shell(r, strings.NewReader(stdin), &out, &errOut)
	return status, out.String(), errOut.String()
}

func TestShellWithDevzoneContext(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "exec -it", stdout: "bash prompt\n"},
	}}
	status, out, errOut := runShell(r, "ls\n")
	if status != 0 || out != "bash prompt\n" || errOut != "" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
	wantCalls(t, r.calls, contextsCall, "--context devzone "+shellExec)
}

func TestShellCurrentContextWhenDevzoneMissing(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "exec -it", stdout: "bash prompt\n"},
	}}
	if status, _, _ := runShell(r, ""); status != 0 {
		t.Fatalf("status %d, want 0", status)
	}
	wantCalls(t, r.calls, contextsCall, shellExec)
}

func TestShellPassesStdinOnToKubectl(t *testing.T) {
	// The terminal of the user is the standard input of kubectl: the fake records what it reads
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "exec -it", stdout: "bash prompt\n"},
	}}
	runShell(r, "echo typed\n")
	if got := r.stdins[len(r.stdins)-1]; got != "echo typed\n" {
		t.Fatalf("stdin of kubectl exec = %q, want the typed input", got)
	}
}

func TestShellKeepsKubectlStatus(t *testing.T) {
	// The status of kubectl is returned as it is, for instance 130 after Ctrl-C
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "exec -it", stderr: "error: interrupted\n", status: 130},
	}}
	status, _, errOut := runShell(r, "")
	if status != 130 || errOut != "error: interrupted\n" {
		t.Fatalf("status %d, stderr %q, want 130 and the kubectl message", status, errOut)
	}
}

func TestShellKubectlCannotStart(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "exec -it", err: errors.New("executable file not found")},
	}}
	status, out, errOut := runShell(r, "")
	if status != 127 || out != "" {
		t.Fatalf("status %d, stdout %q, want 127 and no output", status, out)
	}
	if !strings.Contains(errOut, "cannot start kubectl") {
		t.Fatalf("stderr = %q, want the cannot start message", errOut)
	}
}
