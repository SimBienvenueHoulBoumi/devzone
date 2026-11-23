package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTicketStartPodWorktree checks that a start in the pod creates the worktree on a repowarden branch.
func TestTicketStartPodWorktree(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))

	out, _, code := runTicketArgs("558")
	if code != 0 {
		t.Fatalf("ticket 558 status = %d, want 0", code)
	}
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if !strings.HasSuffix(out, wt+"\n") {
		t.Errorf("output = %q, want it to end with %q", out, wt+"\n")
	}
	if !strings.Contains(out, "ticket #558: branch feat/558-test\n") {
		t.Errorf("output = %q, want the ticket and branch line", out)
	}
	if branch := gitOut(t, wt, "branch", "--show-current"); branch != "feat/558-test" {
		t.Errorf("branch = %q, want feat/558-test", branch)
	}
}

// TestTicketStartRepowardenRepo checks that the repowarden repo gets its own rw worktree in the pod.
func TestTicketStartRepowardenRepo(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "repowarden"))

	_, _, code := runTicketArgs("12", "--repo", "repowarden")
	if code != 0 {
		t.Fatalf("ticket 12 --repo repowarden status = %d, want 0", code)
	}
	wt := filepath.Join(f.projects, "repowarden-wt", "rw-12")
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		t.Errorf("worktree %s is missing: %v", wt, err)
	}
}

// TestTicketStartToolsContainer checks that a start outside the pod uses the tools workspace.
func TestTicketStartToolsContainer(t *testing.T) {
	f := newTicketFixture(t)
	f.clone(t, f.tools)

	_, _, code := runTicketArgs("7")
	if code != 0 {
		t.Fatalf("ticket 7 status = %d, want 0", code)
	}
	wt := filepath.Join(f.tools, "workspace", "wt", "dz-7")
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		t.Errorf("worktree %s is missing: %v", wt, err)
	}
}

// TestTicketStartRepowardenRefusedOutsidePod checks that repowarden tickets are refused outside the pod.
func TestTicketStartRepowardenRefusedOutsidePod(t *testing.T) {
	newTicketFixture(t)

	_, errOut, code := runTicketArgs("7", "--repo", "repowarden")
	if code != 2 {
		t.Fatalf("ticket 7 --repo repowarden status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "only in the Kubernetes workspace pod") {
		t.Errorf("error output = %q", errOut)
	}
}

// TestTicketStartMissingClone checks that a start without a clone points to the workspace clone command.
func TestTicketStartMissingClone(t *testing.T) {
	newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")

	_, errOut, code := runTicketArgs("558")
	if code != 2 {
		t.Fatalf("ticket 558 status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "devzone workspace clone") {
		t.Errorf("error output = %q", errOut)
	}
}

// TestTicketStartExistingWorktreeReused checks that a second start reuses the worktree already there.
func TestTicketStartExistingWorktreeReused(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))

	if _, _, code := runTicketArgs("558"); code != 0 {
		t.Fatalf("first ticket 558 status = %d, want 0", code)
	}
	out, _, code := runTicketArgs("558")
	if code != 0 {
		t.Fatalf("second ticket 558 status = %d, want 0", code)
	}
	if !strings.Contains(out, "already there") {
		t.Errorf("output = %q, want already there", out)
	}
}

// TestTicketStartRepowardenFailureRemovesWorktree checks that a failing repowarden rolls the worktree back.
func TestTicketStartRepowardenFailureRemovesWorktree(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	t.Setenv("FAKE_RW_FAIL", "1")

	_, errOut, code := runTicketArgs("558")
	if code != 2 {
		t.Fatalf("ticket 558 status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "repowarden ticket 558 failed, worktree removed") {
		t.Errorf("error output = %q", errOut)
	}
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if _, err := os.Stat(wt); err == nil {
		t.Errorf("worktree %s is still there", wt)
	}
}

// TestTicketStartBadArguments checks that invalid command lines print the usage and return status 1.
func TestTicketStartBadArguments(t *testing.T) {
	newTicketFixture(t)

	_, errOut, code := runTicketArgs("abc")
	if code != 1 {
		t.Fatalf("ticket abc status = %d, want 1", code)
	}
	if !strings.Contains(errOut, "usage: devzone ticket") {
		t.Errorf("error output = %q", errOut)
	}
	if _, _, code := runTicketArgs("5", "--repo"); code != 1 {
		t.Errorf("ticket 5 --repo status = %d, want 1", code)
	}
}

// TestTicketStartFetchFailureStops checks that a failing fetch stops the start before the worktree.
func TestTicketStartFetchFailureStops(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	if err := os.RemoveAll(f.origin); err != nil {
		t.Fatal(err)
	}

	_, _, code := runTicketArgs("558")
	if code != 128 {
		t.Errorf("ticket 558 status = %d, want 128", code)
	}
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if _, err := os.Stat(wt); err == nil {
		t.Errorf("worktree %s exists although the fetch failed", wt)
	}
}

// TestTicketStartNoBranchShown checks that a repowarden that checks out nothing reports the branch none.
func TestTicketStartNoBranchShown(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "repowarden"), []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	out, _, code := runTicketArgs("558")
	if code != 0 {
		t.Fatalf("ticket 558 status = %d, want 0", code)
	}
	if !strings.Contains(out, "ticket #558: branch none") {
		t.Errorf("output = %q, want the branch none line", out)
	}
}
