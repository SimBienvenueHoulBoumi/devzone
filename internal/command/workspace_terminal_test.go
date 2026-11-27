package command

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// shellRunner answers the kubectl calls of "workspace shell" in memory, like
// the fake kubectl of the former shell tests, without any PATH entry.
type shellRunner struct {
	status int
	out    string
}

// Kubectl answers the exec call and keeps the status of kubectl.
func (r *shellRunner) Kubectl(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	if strings.Contains(strings.Join(args, " "), "exec -it") {
		_, _ = io.WriteString(stdout, r.out)
	}
	return r.status, nil
}

// Helm answers nothing.
func (r *shellRunner) Helm(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	return 0, nil
}

func TestWorkspaceShellRunsInGo(t *testing.T) {
	r := &shellRunner{status: 0, out: "kubectl exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash\n"}
	useStopTools(t, r, fake.New())
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
	r := &shellRunner{status: 3, out: "kubectl exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash\n"}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "shell"}, &out, &errOut); got != 3 {
		t.Fatalf("exit status = %d, want 3 (the status of kubectl)", got)
	}
}

func TestWorkspaceShellWithWordsIsIgnored(t *testing.T) {
	r := &shellRunner{status: 0, out: "kubectl exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash\n"}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "shell", "extra"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(out.String(), "kubectl exec -it") {
		t.Fatalf("stdout = %q: want the shell written by Go, not a delegation", out.String())
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

func TestWorkspaceVSCodeWithWordsIsIgnored(t *testing.T) {
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "vscode", "extra"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0", got)
	}
	if !strings.Contains(out.String(), "Pod not ready: devzone workspace status") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want the guide written by Go, not a delegation", out.String())
	}
}
