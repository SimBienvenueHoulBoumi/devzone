package command

import (
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// runWorkspace runs workspaceCommand with the given args and returns the stderr
// output and the exit code, so edge-case tests can check the usage messages.
func runWorkspace(args ...string) (string, int) {
	var out, errOut strings.Builder
	code := workspaceCommand(&cli.Context{Args: args, Out: &out, Err: &errOut})
	return errOut.String(), code
}

// TestCopyToWithoutFolderGivesUsage checks that copy-to with no folder prints
// the usage and fails, as the command always did.
func TestCopyToWithoutFolderGivesUsage(t *testing.T) {
	got, code := runWorkspace("copy-to")
	if code != 1 {
		t.Fatalf("exit status = %d, want 1", code)
	}
	want := "provide a workstation folder: devzone workspace copy-to <folder>"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr = %q, want it to contain %q", got, want)
	}
	if strings.Contains(got, "bash entry point") {
		t.Fatalf("stderr = %q, must not be delegated to bash", got)
	}
}

// TestCopyFromWithoutFolderGivesUsage checks that copy-from with no folder
// prints the usage and fails, as the command always did.
func TestCopyFromWithoutFolderGivesUsage(t *testing.T) {
	got, code := runWorkspace("copy-from")
	if code != 1 {
		t.Fatalf("exit status = %d, want 1", code)
	}
	want := "provide a workstation folder: devzone workspace copy-from <folder>"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr = %q, want it to contain %q", got, want)
	}
	if strings.Contains(got, "bash entry point") {
		t.Fatalf("stderr = %q, must not be delegated to bash", got)
	}
}

// TestCopyToExtraWordsAreIgnored checks that copy-to keeps only the folder
// argument and ignores extra words, as the command always did.
func TestCopyToExtraWordsAreIgnored(t *testing.T) {
	got, code := runWorkspace("copy-to", "/nonexistent-dz-test-folder", "extra", "words")
	if code != 1 {
		t.Fatalf("exit status = %d, want 1", code)
	}
	want := "folder not found: /nonexistent-dz-test-folder"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr = %q, want it to contain %q", got, want)
	}
	if strings.Contains(got, "bash entry point") {
		t.Fatalf("stderr = %q, must not be delegated to bash", got)
	}
}

// TestCloneWithoutUrlGivesUsage checks that clone with no URL prints the usage
// and fails, as the command always did.
func TestCloneWithoutUrlGivesUsage(t *testing.T) {
	got, code := runWorkspace("clone")
	if code != 1 {
		t.Fatalf("exit status = %d, want 1", code)
	}
	want := "usage: devzone workspace clone <url> [<name>]"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr = %q, want it to contain %q", got, want)
	}
	if strings.Contains(got, "bash entry point") {
		t.Fatalf("stderr = %q, must not be delegated to bash", got)
	}
}

// TestCloneWithTooManyWordsGivesUsage checks that clone with more than two
// arguments prints the usage and fails, as the command always did.
func TestCloneWithTooManyWordsGivesUsage(t *testing.T) {
	got, code := runWorkspace("clone", "a", "b", "c")
	if code != 1 {
		t.Fatalf("exit status = %d, want 1", code)
	}
	want := "usage: devzone workspace clone <url> [<name>]"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr = %q, want it to contain %q", got, want)
	}
	if strings.Contains(got, "bash entry point") {
		t.Fatalf("stderr = %q, must not be delegated to bash", got)
	}
}

// TestCloneRoutesUrlAndNameToGo checks that clone with a URL and a name routes
// to /workspaces/projets/<name> and runs the clone in the pod.
func TestCloneRoutesUrlAndNameToGo(t *testing.T) {
	r := &statusRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut strings.Builder
	code := workspaceCommand(&cli.Context{Args: []string{"clone", "https://github.com/acme/mine.git", "custom"}, Out: &out, Err: &errOut})
	if code != 0 {
		t.Fatalf("exit status = %d, want 0", code)
	}
	found := false
	for _, c := range r.calls {
		if strings.Contains(c, "/workspaces/projets/custom") && strings.Contains(c, "https://github.com/acme/mine.git") {
			found = true
		}
	}
	if !found {
		t.Fatalf("kubectl not called with the clone of /workspaces/projets/custom: %v", r.calls)
	}
}

// TestCloneRoutesUrlOnlyToGo checks that clone with only a URL routes to
// /workspaces/projets/<last-segment-of-url> and runs the clone in the pod.
func TestCloneRoutesUrlOnlyToGo(t *testing.T) {
	r := &statusRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut strings.Builder
	code := workspaceCommand(&cli.Context{Args: []string{"clone", "https://github.com/acme/mine.git"}, Out: &out, Err: &errOut})
	if code != 0 {
		t.Fatalf("exit status = %d, want 0", code)
	}
	found := false
	for _, c := range r.calls {
		if strings.Contains(c, "/workspaces/projets/mine") {
			found = true
		}
	}
	if !found {
		t.Fatalf("kubectl not called with the clone of /workspaces/projets/mine: %v", r.calls)
	}
}
