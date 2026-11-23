package command

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// runWorkspace runs workspaceCommand with the given args and returns the stderr
// output and the exit code, so edge-case tests can check the usage messages.
func runWorkspace(args ...string) (string, int) {
	var out, errOut strings.Builder
	code := workspaceCommand(args, &out, &errOut)
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

// fakeKubectlLogging creates a fake kubectl script in a temp directory and
// prepends it to PATH so that workspaceCommand runs as if via kubectl logging.
// It returns the path to the kubectl log file.
func fakeKubectlLogging(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "kubectl.log")
	if err := os.WriteFile(filepath.Join(dir, "kubectl"), []byte("#!/bin/sh\necho \"$*\" >>"+logPath+"\ncase \"$*\" in\n    *\"get pods\"*) echo 'devzone-workspace-0  1/1  Running' ;;\n    *\"exec\"*) cat >/dev/null ;;\nesac\n exit 0\n"), 0o755); err != nil {
		t.Fatalf("failed to write fake kubectl: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return logPath
}

// TestCloneRoutesUrlAndNameToGo checks that clone with a URL and a name routes
// to /workspaces/projets/<name> and logs the URL.
func TestCloneRoutesUrlAndNameToGo(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	logPath := fakeKubectlLogging(t)
	var out, errOut strings.Builder
	code := workspaceCommand([]string{"clone", "https://github.com/acme/mine.git", "custom"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0", code)
	}
	logOutput, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("failed to read kubectl log: %v", err)
	}
	logStr := string(logOutput)
	if !strings.Contains(logStr, "/workspaces/projets/custom") {
		t.Fatalf("log does not contain /workspaces/projets/custom, got %q", logStr)
	}
	if !strings.Contains(logStr, "https://github.com/acme/mine.git") {
		t.Fatalf("log does not contain https://github.com/acme/mine.git, got %q", logStr)
	}
}

// TestCloneRoutesUrlOnlyToGo checks that clone with only a URL routes to
// /workspaces/projets/<last-segment-of-url> and logs the URL.
func TestCloneRoutesUrlOnlyToGo(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl is a shell script")
	}
	logPath := fakeKubectlLogging(t)
	var out, errOut strings.Builder
	code := workspaceCommand([]string{"clone", "https://github.com/acme/mine.git"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("exit status = %d, want 0", code)
	}
	logOutput, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("failed to read kubectl log: %v", err)
	}
	logStr := string(logOutput)
	if !strings.Contains(logStr, "/workspaces/projets/mine") {
		t.Fatalf("log does not contain /workspaces/projets/mine, got %q", logStr)
	}
	if strings.Contains(logStr, "/workspaces/projets/custom") {
		t.Fatalf("log must not contain /workspaces/projets/custom, got %q", logStr)
	}
}
