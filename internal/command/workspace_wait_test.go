package command

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// waitRunner answers the kubectl reads of a wait in order and records the
// undeploy, so a test needs no cluster and no sleep.
type waitRunner struct {
	answers []string
	helm    int
}

// Kubectl returns the next programmed answer, or an empty one when the list is
// exhausted; the context lookup is answered like a kubeconfig without devzone.
func (f *waitRunner) Kubectl(args []string, _ io.Reader, out, _ io.Writer) (int, error) {
	line := strings.Join(args, " ")
	if strings.Contains(line, "config get-contexts") {
		return 0, nil
	}
	if len(f.answers) > 0 {
		answer := f.answers[0]
		f.answers = f.answers[1:]
		_, _ = io.WriteString(out, answer)
	}
	return 0, nil
}

// Helm records that the failed image removed the chart.
func (f *waitRunner) Helm(_ []string, _ io.Reader, _, _ io.Writer) (int, error) {
	f.helm++
	return 0, nil
}

// TestPodWaitWithFakeRunner checks the pull failure of the shell wait with a
// fake Runner: the reason is printed and the undeploy stays silent.
func TestPodWaitWithFakeRunner(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE_WAIT", "1")
	t.Setenv("DEVZONE_WORKSPACE_STEP", "0")
	f := &waitRunner{answers: []string{"rev1", "rev1", "Pending ImagePullBackOff", "manifest invalid"}}
	var out, errOut bytes.Buffer
	if code := runPodWaitWith(f, "repo:1", &out, &errOut); code != 1 {
		t.Fatalf("status = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "✖ image repo:1 not found") || out.Len() != 0 {
		t.Fatalf("stdout = %q, stderr = %q", out.String(), errOut.String())
	}
	if f.helm != 1 {
		t.Fatalf("undeploy calls = %d, want 1", f.helm)
	}
}

// TestPodWaitCommandRoutesImage checks that the internal command sends its one
// image argument to the Go wait and propagates its status.
func TestPodWaitCommandRoutesImage(t *testing.T) {
	previous := commandPodWait
	t.Cleanup(func() { commandPodWait = previous })
	image := ""
	commandPodWait = func(got string, _, _ io.Writer) int {
		image = got
		return 7
	}
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"wait", "repo:1"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 7 {
		t.Fatalf("status = %d, want 7", code)
	}
	if image != "repo:1" {
		t.Fatalf("image = %q, want repo:1", image)
	}
}

// TestPodWaitCommandKeepsStreams checks that the messages of the wait reach the
// output and error streams of the caller, as the shell function wrote them.
func TestPodWaitCommandKeepsStreams(t *testing.T) {
	previous := commandPodWait
	t.Cleanup(func() { commandPodWait = previous })
	commandPodWait = func(_ string, out, errOut io.Writer) int {
		_, _ = io.WriteString(out, "✔ workspace started\n")
		_, _ = io.WriteString(errOut, "⚠ pod not ready\n")
		return 0
	}
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"wait", "repo:1"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, want 0", code)
	}
	if out.String() != "✔ workspace started\n" || errOut.String() != "⚠ pod not ready\n" {
		t.Fatalf("stdout = %q, stderr = %q", out.String(), errOut.String())
	}
}

// TestPodWaitCommandUsage checks that a missing or empty image is refused
// before any cluster call, with the status of a command-line error.
func TestPodWaitCommandUsage(t *testing.T) {
	previous := commandPodWait
	t.Cleanup(func() { commandPodWait = previous })
	calls := 0
	commandPodWait = func(string, io.Writer, io.Writer) int { calls++; return 0 }
	for _, args := range [][]string{{"wait"}, {"wait", ""}, {"wait", "a", "b"}} {
		var errOut bytes.Buffer
		ctx := &cli.Context{Args: args, Out: &bytes.Buffer{}, Err: &errOut}
		if code := workspaceCommand(ctx); code != 2 {
			t.Fatalf("args %q: status = %d, want 2", args, code)
		}
		if !strings.Contains(errOut.String(), "usage: devzone workspace wait <image>") {
			t.Fatalf("args %q: stderr = %q", args, errOut.String())
		}
	}
	if calls != 0 {
		t.Fatalf("wait called %d times on bad arguments", calls)
	}
}
