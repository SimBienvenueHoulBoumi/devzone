package workspace

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// noOrigin is the origin of a folder without remote
func noOrigin(string) string { return "" }

// copyFake answers the calls of a copy: no devzone context declared, the guard
// answered with guardStatus and guardOut, and kubectl cp with status 0.
func copyFake(guardStatus int, guardOut string) *fakeRunner {
	return &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "lab\n"},
		{match: "exec -i", status: guardStatus, stdout: guardOut},
		{match: "cp ", stdout: "copied\n"},
	}}
}

// lastCall returns the last kubectl call recorded by the fake
func lastCall(t *testing.T, f *fakeRunner) string {
	t.Helper()
	if len(f.calls) == 0 {
		t.Fatal("no kubectl call")
	}
	return f.calls[len(f.calls)-1]
}

func TestCopyToWithoutFolder(t *testing.T) {
	f := copyFake(0, "")
	var errOut bytes.Buffer
	if got := CopyTo(f, noOrigin, "", &bytes.Buffer{}, &errOut); got != 1 {
		t.Fatalf("status = %d, want 1", got)
	}
	if errOut.String() != copyToUsage+"\n" || len(f.calls) != 0 {
		t.Fatalf("stderr %q, calls %v: want the usage and no kubectl call", errOut.String(), f.calls)
	}
}

func TestCopyToFolderNotFound(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "absent")
	f := copyFake(0, "")
	var errOut bytes.Buffer
	if got := CopyTo(f, noOrigin, missing, &bytes.Buffer{}, &errOut); got != 1 {
		t.Fatalf("status = %d, want 1", got)
	}
	if want := "✖ folder not found: " + missing + "\n"; errOut.String() != want || len(f.calls) != 0 {
		t.Fatalf("stderr %q, calls %v: want %q and no kubectl call", errOut.String(), f.calls, want)
	}
}

func TestCopyToFileIsNotAFolder(t *testing.T) {
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := copyFake(0, "")
	var errOut bytes.Buffer
	if got := CopyTo(f, noOrigin, file, &bytes.Buffer{}, &errOut); got != 1 || !strings.Contains(errOut.String(), "folder not found") {
		t.Fatalf("status %d, stderr %q: want 1 and folder not found", got, errOut.String())
	}
}

func TestCopyToEmptyFolderIsCopied(t *testing.T) {
	dir := t.TempDir()
	f := copyFake(0, "")
	var out bytes.Buffer
	if got := CopyTo(f, noOrigin, dir, &out, &bytes.Buffer{}); got != 0 {
		t.Fatalf("status = %d, want 0", got)
	}
	want := "cp " + dir + " devzone-workspace-0:/workspaces/projets/" + filepath.Base(dir) + " --namespace devzone-workspace -c workspace"
	if got := lastCall(t, f); got != want {
		t.Fatalf("kubectl call = %q, want %q", got, want)
	}
	if out.String() != "copied\n" {
		t.Fatalf("stdout = %q: want the output of kubectl cp", out.String())
	}
}

func TestCopyToGuardGetsFolderAndRemote(t *testing.T) {
	dir := t.TempDir()
	f := copyFake(0, "")
	origin := func(string) string { return "https://github.com/acme/mine.git" }
	CopyTo(f, origin, dir, &bytes.Buffer{}, &bytes.Buffer{})
	guard := f.calls[1]
	if !strings.Contains(guard, "exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash -s -- /workspaces/projets/"+filepath.Base(dir)+" https://github.com/acme/mine.git") {
		t.Fatalf("guard call = %q: want the pod folder and the remote as arguments", guard)
	}
	if f.stdins[1] != copyGuardScript {
		t.Fatalf("guard script = %q, want copyGuardScript", f.stdins[1])
	}
}

func TestCopyToRefusesOtherRemote(t *testing.T) {
	dir := t.TempDir()
	f := copyFake(guardRefused, "https://github.com/other/mine.git\n")
	origin := func(string) string { return "https://github.com/acme/mine.git" }
	var errOut bytes.Buffer
	if got := CopyTo(f, origin, dir, &bytes.Buffer{}, &errOut); got != 1 {
		t.Fatalf("status = %d, want 1", got)
	}
	want := "✖ /workspaces/projets/" + filepath.Base(dir) + " in the pod is a git clone with another remote" +
		" (https://github.com/other/mine.git, here: https://github.com/acme/mine.git); not overwritten\n" +
		"  work in that clone (devzone workspace clone), or remove it first\n"
	if errOut.String() != want {
		t.Fatalf("stderr =\n%q\nwant\n%q", errOut.String(), want)
	}
	for _, call := range f.calls {
		if strings.HasPrefix(call, "cp ") {
			t.Fatalf("kubectl cp called after a refusal: %q", call)
		}
	}
}

func TestCopyToRefusalWithoutLocalRemote(t *testing.T) {
	f := copyFake(guardRefused, "https://github.com/other/mine.git\n")
	var errOut bytes.Buffer
	CopyTo(f, noOrigin, t.TempDir(), &bytes.Buffer{}, &errOut)
	if !strings.Contains(errOut.String(), ", here: none)") {
		t.Fatalf("stderr %q: want \"here: none\" when the workstation folder has no remote", errOut.String())
	}
}

func TestCopyToGuardUnreachablePodCopies(t *testing.T) {
	// No reply for the guard: the call fails, and the copy goes on as in bash
	f := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "lab\n"},
		{match: "cp ", stdout: "copied\n"},
	}}
	if got := CopyTo(f, noOrigin, t.TempDir(), &bytes.Buffer{}, &bytes.Buffer{}); got != 0 {
		t.Fatalf("status = %d, want 0 (copy after an unreachable guard)", got)
	}
}

func TestCopyToDevzoneContext(t *testing.T) {
	f := copyFake(0, "")
	f.replies[0].stdout = "lab\n" + fexec.ContextName() + "\n"
	CopyTo(f, noOrigin, t.TempDir(), &bytes.Buffer{}, &bytes.Buffer{})
	if got := lastCall(t, f); !strings.HasPrefix(got, "--context "+fexec.ContextName()+" cp ") {
		t.Fatalf("kubectl call = %q: want the services context flag", got)
	}
}

func TestCopyToStatusOfKubectl(t *testing.T) {
	f := copyFake(0, "")
	f.replies[2].status = 5
	if got := CopyTo(f, noOrigin, t.TempDir(), &bytes.Buffer{}, &bytes.Buffer{}); got != 5 {
		t.Fatalf("status = %d, want 5 (status of kubectl cp)", got)
	}
}

func TestCopyToKubectlCannotStart(t *testing.T) {
	// Only the guard and the context are answered: the copy is an error
	f := &fakeRunner{replies: []reply{
		{match: "config get-contexts", stdout: "lab\n"},
		{match: "exec -i", stdout: ""},
	}}
	var errOut bytes.Buffer
	if got := CopyTo(f, noOrigin, t.TempDir(), &bytes.Buffer{}, &errOut); got != notStarted {
		t.Fatalf("status = %d, want %d", got, notStarted)
	}
	if !strings.HasPrefix(errOut.String(), "devzone: cannot start kubectl:") {
		t.Fatalf("stderr = %q", errOut.String())
	}
}

func TestCopyFromWithoutFolder(t *testing.T) {
	f := copyFake(0, "")
	var errOut bytes.Buffer
	if got := CopyFrom(f, "", &bytes.Buffer{}, &errOut); got != 1 {
		t.Fatalf("status = %d, want 1", got)
	}
	if errOut.String() != copyFromUsage+"\n" || len(f.calls) != 0 {
		t.Fatalf("stderr %q, calls %v: want the usage and no kubectl call", errOut.String(), f.calls)
	}
}

func TestCopyFromMissingFolderKeepsItsName(t *testing.T) {
	f := copyFake(0, "")
	if got := CopyFrom(f, "absent/mine", &bytes.Buffer{}, &bytes.Buffer{}); got != 0 {
		t.Fatalf("status = %d, want 0", got)
	}
	want := "cp devzone-workspace-0:/workspaces/projets/mine absent/mine --namespace devzone-workspace -c workspace"
	if got := lastCall(t, f); got != want {
		t.Fatalf("kubectl call = %q, want %q", got, want)
	}
}

func TestCopyFromCurrentFolderIsAbsolute(t *testing.T) {
	dir := t.TempDir()
	t.Chdir(dir)
	f := copyFake(0, "")
	CopyFrom(f, ".", &bytes.Buffer{}, &bytes.Buffer{})
	want := "cp devzone-workspace-0:/workspaces/projets/" + filepath.Base(dir) + " " + dir +
		" --namespace devzone-workspace -c workspace"
	if got := lastCall(t, f); got != want {
		t.Fatalf("kubectl call = %q, want %q", got, want)
	}
}

func TestCopyFromStatusOfKubectl(t *testing.T) {
	f := copyFake(0, "")
	f.replies[2].status = 7
	if got := CopyFrom(f, t.TempDir(), &bytes.Buffer{}, &bytes.Buffer{}); got != 7 {
		t.Fatalf("status = %d, want 7 (status of kubectl cp)", got)
	}
}

func TestCopyFromKubectlMissing(t *testing.T) {
	f := &fakeRunner{replies: []reply{{match: "config get-contexts", stdout: "lab\n"}}}
	f.replies = append(f.replies, reply{match: "cp ", err: errors.New("not found")})
	if got := CopyFrom(f, "x", &bytes.Buffer{}, &bytes.Buffer{}); got != notStarted {
		t.Fatalf("status = %d, want %d", got, notStarted)
	}
}

func TestOriginReadsOriginRemote(t *testing.T) {
	requireGit(t)
	dir := t.TempDir()
	runGit(t, dir, "init", "-q")
	runGit(t, dir, "remote", "add", "origin", "https://github.com/acme/mine.git")
	if got := Origin(dir); got != "https://github.com/acme/mine.git" {
		t.Fatalf("Origin = %q", got)
	}
}

func TestOriginWithoutOriginIsEmpty(t *testing.T) {
	requireGit(t)
	dir := t.TempDir()
	runGit(t, dir, "init", "-q")
	if got := Origin(dir); got != "" {
		t.Fatalf("Origin = %q, want empty for a repository without origin", got)
	}
}
