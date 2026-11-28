package workspace

import (
	"bytes"
	"errors"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// argocdMemoryRun runs argocdMemoryOK on r and returns its status and error
// output.
func argocdMemoryRun(r Runner) (int, string) {
	var errOut bytes.Buffer
	status := argocdMemoryOK(r, &errOut)
	return status, errOut.String()
}

// argocdMemoryUnreachable is the error output of argocdMemoryOK when the
// cluster does not answer.
const argocdMemoryUnreachable = "✖ argocd: cluster unreachable or nodes unreadable (kubectl config get-contexts)\n"

// argocdMemoryRefusal is the error output of argocdMemoryOK when the cluster
// has less allocatable memory than the minimum.
const argocdMemoryRefusal = "✖ argocd: at least 1 Gi of allocatable memory is needed in the cluster (available: 1023 Mi); enlarge the memory of the cluster, then: devzone workspace services enable argocd\n"

// TestArgocdMemoryOK checks the answer of argocdMemoryOK: enough memory, the
// exact minimum, less memory, empty lines, empty output, an output reduced to
// newlines, trailing newlines after a value, failing kubectl and kubectl that
// cannot start.
func TestArgocdMemoryOK(t *testing.T) {
	cases := []struct {
		name    string
		replies []reply
		want    int
		wantErr string
	}{
		{"one node of 4 Gi is enough", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "4Gi\n"},
		}, 0, ""},
		{"two nodes of 512 Mi total 1 Gi pass", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "512Mi\n512Mi"},
		}, 0, ""},
		{"memory just below 1 Gi is refused", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "1048575Ki\n"},
		}, 2, argocdMemoryRefusal},
		{"mixed units of several nodes pass", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "1Gi\n512Mi\n256Ki"},
		}, 0, ""},
		{"empty lines are ignored", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "1Gi\n\n512Mi"},
		}, 0, ""},
		{"empty output", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: ""},
		}, 2, argocdMemoryUnreachable},
		{"output of a single newline", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "\n"},
		}, 2, argocdMemoryUnreachable},
		{"output of newlines only", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "\n\n\n"},
		}, 2, argocdMemoryUnreachable},
		{"trailing newlines after a value", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "4Gi\n\n"},
		}, 0, ""},
		{"failing kubectl is treated as empty", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", stdout: "2Gi\n", status: 1},
		}, 2, argocdMemoryUnreachable},
		{"kubectl that cannot start is treated as empty", []reply{
			{match: contextsCall, stdout: devzoneContexts},
			{match: "get nodes -o jsonpath", err: errors.New("exec: kubectl not found")},
		}, 2, argocdMemoryUnreachable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, errOut := argocdMemoryRun(&fakeRunner{replies: tc.replies})
			if status != tc.want || errOut != tc.wantErr {
				t.Fatalf("argocdMemoryOK = %d, %q; want %d, %q", status, errOut, tc.want, tc.wantErr)
			}
		})
	}
}

// TestArgocdMemoryOKContextFlag checks that the nodes call of the memory check
// carries the devzone context flag when the kubeconfig declares it, and no flag
// otherwise.
func TestArgocdMemoryOKContextFlag(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get nodes -o jsonpath", stdout: "4Gi\n"},
	}}
	if status, _ := argocdMemoryRun(r); status != 0 {
		t.Fatalf("argocdMemoryOK = %d, want 0", status)
	}
	wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+` get nodes -o jsonpath={range .items[*]}{.status.allocatable.memory}{"\n"}{end}`)

	r = &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "get nodes -o jsonpath", stdout: "4Gi\n"},
	}}
	if status, _ := argocdMemoryRun(r); status != 0 {
		t.Fatalf("argocdMemoryOK = %d, want 0", status)
	}
	wantCalls(t, r.calls, contextsCall, `get nodes -o jsonpath={range .items[*]}{.status.allocatable.memory}{"\n"}{end}`)
}
