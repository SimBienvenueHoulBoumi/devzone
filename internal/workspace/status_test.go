package workspace

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// podTable is what kubectl get pods prints for a running workspace pod
const podTable = "NAME                 READY   STATUS    RESTARTS   AGE\n" +
	"devzone-workspace-0  1/1     Running   0          2d\n"

// Joined arguments of the calls of Status, with the devzone context
const (
	podsWithContext  = "--context devzone get pods --namespace devzone-workspace"
	podsCurrent      = "get pods --namespace devzone-workspace"
	execWithContext  = "--context devzone exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash -s -- /workspaces/projets"
	contextsCall     = "config get-contexts -o name"
	noLegacyCopies   = "exec -i"
	devzoneContexts  = "lab\ndevzone\n"
	currentContext   = "lab\n"
	absentPodMessage = "No resources found in devzone-workspace namespace.\n"
)

// runStatus runs Status on r with an empty fake work folder, so the real pod
// files cannot add a core warning, and returns its status, output and error.
func runStatus(t *testing.T, r Runner) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	status := StatusWith(r, &out, &errOut, t.TempDir(), func(string) int64 { return 0 })
	return status, out.String(), errOut.String()
}

// wantCalls fails the test unless the recorded calls are exactly want
func wantCalls(t *testing.T, got []string, want ...string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("calls = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("call %d = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestStatusPodRunning(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, status: 1},
	}}
	status, out, errOut := runStatus(t, r)
	if status != 0 || out != podTable || errOut != "" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
	// The pod script is run through a second context lookup, as in the bash entry point
	wantCalls(t, r.calls, contextsCall, podsWithContext, contextsCall, execWithContext)
}

func TestStatusCurrentContextWhenDevzoneMissing(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, status: 1},
	}}
	status, out, _ := runStatus(t, r)
	if status != 0 || out != podTable {
		t.Fatalf("status %d, stdout %q", status, out)
	}
	wantCalls(t, r.calls, contextsCall, podsCurrent, contextsCall,
		"exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash -s -- /workspaces/projets")
}

func TestStatusCurrentContextWhenContextListFails(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts, status: 1},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, status: 1},
	}}
	runStatus(t, r)
	if r.calls[1] != podsCurrent {
		t.Fatalf("get pods call = %q, want %q", r.calls[1], podsCurrent)
	}
}

func TestStatusPodAbsent(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stderr: absentPodMessage},
		{match: noLegacyCopies, status: 1},
	}}
	status, out, errOut := runStatus(t, r)
	if status != 0 || out != "" || errOut != absentPodMessage {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
}

func TestStatusPodFailing(t *testing.T) {
	table := "NAME                 READY   STATUS             RESTARTS   AGE\n" +
		"devzone-workspace-0  0/1     CrashLoopBackOff   5          2d\n"
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stdout: table},
		{match: noLegacyCopies, status: 1},
	}}
	status, out, errOut := runStatus(t, r)
	if status != 0 || out != table || errOut != "" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
}

func TestStatusKubectlFailsKeepsItsStatus(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stderr: "Unable to connect to the server\n", status: 1},
	}}
	status, out, errOut := runStatus(t, r)
	if status != 1 || out != "" || errOut != "Unable to connect to the server\n" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
	wantCalls(t, r.calls, contextsCall, podsWithContext)
}

func TestStatusKubectlNotStarted(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, err: errors.New("exec: kubectl not found")},
		{match: "get pods", err: errors.New("exec: kubectl not found")},
	}}
	status, out, errOut := runStatus(t, r)
	if status != 127 || out != "" || !strings.Contains(errOut, "cannot start kubectl") {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
}

func TestStatusLegacyCopiesReported(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, stdout: "repogarde\nwt\n"},
	}}
	status, out, errOut := runStatus(t, r)
	want := podTable + legacyMessage([]string{"repogarde", "wt"})
	if status != 0 || out != want || errOut != "" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
}

func TestStatusLegacyCheckUnreachablePodIsSilent(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, stdout: "repogarde\n", status: 1},
	}}
	status, out, _ := runStatus(t, r)
	if status != 0 || out != podTable {
		t.Fatalf("status %d, stdout %q", status, out)
	}
}

func TestStatusSendsPodScriptOnStdin(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, status: 1},
	}}
	runStatus(t, r)
	script := r.stdins[len(r.stdins)-1]
	if !strings.HasPrefix(script, "broken() {") || !strings.Contains(script, "for d in wt/*") {
		t.Fatalf("pod script not sent on stdin: %q", script)
	}
}

// coreStatusRunner answers the kubectl calls of Status without a cluster.
func coreStatusRunner() *fakeRunner {
	return &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get pods", stdout: podTable},
		{match: noLegacyCopies, status: 1},
	}}
}

// TestStatusWarnsOnLargeCoreDump checks that one line reports a core file over
// the limit in a worktree, with injected sizes and no real large file.
func TestStatusWarnsOnLargeCoreDump(t *testing.T) {
	root := t.TempDir()
	work := filepath.Join(root, "workspace", "wt", "dz-961")
	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	big := filepath.Join(work, "core.123")
	small := filepath.Join(work, "core")
	for _, path := range []string{big, small} {
		if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	size := func(path string) int64 {
		if path == big {
			return 101 << 20
		}
		return 1 << 20
	}
	var out, errOut bytes.Buffer
	status := StatusWith(coreStatusRunner(), &out, &errOut, root, size)
	want := podTable + "⚠ large core dump in the pod: " + big + " (>100 MiB); remove it before committing\n"
	if status != 0 || out.String() != want || errOut.String() != "" {
		t.Fatalf("status %d, stdout %q, stderr %q, want %q", status, out.String(), errOut.String(), want)
	}
}

// TestStatusIgnoresSmallCoreDumpsAndCoreFolder checks that the warning needs a
// file over the limit and never flags a folder named core.
func TestStatusIgnoresSmallCoreDumpsAndCoreFolder(t *testing.T) {
	root := t.TempDir()
	folder := filepath.Join(root, "workspace", "wt", "dz-961", "core")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	project := filepath.Join(root, "workspace", "projet")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(project, "core"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut bytes.Buffer
	status := StatusWith(coreStatusRunner(), &out, &errOut, root, func(string) int64 { return 99 << 20 })
	if status != 0 || out.String() != podTable || errOut.String() != "" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out.String(), errOut.String())
	}
}
