package command

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// copyRunner answers the kubectl calls of the copy commands in memory, like
// the fake kubectl of the former shell tests, without any PATH entry.
type copyRunner struct{}

// Kubectl answers the copy calls and records them.
func (r *copyRunner) Kubectl(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	return 0, nil
}

// Helm answers nothing.
func (r *copyRunner) Helm(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	return 0, nil
}

func TestWorkspaceCopyToMissingFolderRunsInGo(t *testing.T) {
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "copy-to", "no-such-folder-754"}, &out, &errOut); got != 1 {
		t.Fatalf("exit status = %d, want 1 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(errOut.String(), "✖ folder not found: no-such-folder-754") || strings.Contains(out.String(), "args:") {
		t.Fatalf("stderr = %q, stdout = %q: want the message from Go, not a delegation", errOut.String(), out.String())
	}
}

func TestWorkspaceCopyFromRunsInGo(t *testing.T) {
	r := &copyRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "copy-from", "mine"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if strings.Contains(out.String(), "args:") {
		t.Fatalf("stdout = %q: want kubectl run by Go, not a delegation", out.String())
	}
}
