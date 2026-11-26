package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestTicketDoneRemovesWorktreeAndBranch checks that done removes a clean worktree and its merged local branch.
func TestTicketDoneRemovesWorktreeAndBranch(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	clone := filepath.Join(f.projects, "devzone")
	f.clone(t, clone)
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if _, _, code := runTicketArgs("558"); code != 0 {
		t.Fatalf("ticket 558 status = %d, want 0", code)
	}

	out, _, code := runTicketArgs("done", "558")
	if code != 0 {
		t.Fatalf("ticket done 558 status = %d, want 0", code)
	}
	if _, err := os.Stat(wt); err == nil {
		t.Errorf("worktree %s is still there", wt)
	}
	if branches := gitOut(t, clone, "branch", "--list", "feat/558-test"); branches != "" {
		t.Errorf("local branch still there: %q", branches)
	}
	if !strings.Contains(out, "worktree") || !strings.Contains(out, "local branch feat/558-test removed") {
		t.Errorf("output = %q", out)
	}
}

// TestTicketDoneRefusedWhenNotClean checks that done refuses a worktree with uncommitted files.
func TestTicketDoneRefusedWhenNotClean(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if _, _, code := runTicketArgs("558"); code != 0 {
		t.Fatalf("ticket 558 status = %d, want 0", code)
	}
	if err := os.WriteFile(filepath.Join(wt, "new-file"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	_, errOut, code := runTicketArgs("done", "558")
	if code != 2 {
		t.Fatalf("ticket done 558 status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "not clean") {
		t.Errorf("error output = %q", errOut)
	}
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		t.Errorf("worktree %s was removed: %v", wt, err)
	}
}

// TestTicketDoneRefusedWhileBranchOnOrigin checks that done refuses a branch that is not merged on origin.
func TestTicketDoneRefusedWhileBranchOnOrigin(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if _, _, code := runTicketArgs("558"); code != 0 {
		t.Fatalf("ticket 558 status = %d, want 0", code)
	}
	testkit.Git(t, wt, "push", "-q", "origin", "feat/558-test")

	_, errOut, code := runTicketArgs("done", "558")
	if code != 2 {
		t.Fatalf("ticket done 558 status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "still exists on origin") {
		t.Errorf("error output = %q", errOut)
	}
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		t.Errorf("worktree %s was removed: %v", wt, err)
	}
}

// TestTicketDoneUnknownWorktree checks that done refuses a ticket without a worktree.
func TestTicketDoneUnknownWorktree(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))

	_, errOut, code := runTicketArgs("done", "99")
	if code != 2 {
		t.Fatalf("ticket done 99 status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "no worktree for ticket 99") {
		t.Errorf("error output = %q", errOut)
	}
}

// TestTicketDoneNoneBranchShown checks that a detached worktree is reported with the branch none.
func TestTicketDoneNoneBranchShown(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	clone := filepath.Join(f.projects, "devzone")
	f.clone(t, clone)
	wt := filepath.Join(f.projects, "devzone-wt", "dz-77")
	testkit.Git(t, clone, "worktree", "add", "-q", "--detach", wt, "origin/develop")

	out, _, code := runTicketArgs("done", "77")
	if code != 0 {
		t.Fatalf("ticket done 77 status = %d, want 0", code)
	}
	if !strings.Contains(out, "local branch none removed") {
		t.Errorf("output = %q", out)
	}
}

// TestTicketDonePlainFolderStops checks that done stops on a plain folder that is not a git repository.
func TestTicketDonePlainFolderStops(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	wt := filepath.Join(f.projects, "devzone-wt", "dz-5")
	if err := os.MkdirAll(wt, 0o755); err != nil {
		t.Fatal(err)
	}

	_, errOut, code := runTicketArgs("done", "5")
	if code != 128 {
		t.Fatalf("ticket done 5 status = %d, want 128", code)
	}
	if !strings.Contains(errOut, "not a git repository") {
		t.Errorf("error output = %q", errOut)
	}
	if _, err := os.Stat(wt); err != nil {
		t.Errorf("plain folder %s was removed: %v", wt, err)
	}
}

// TestTicketDoneFileIsNotWorktree checks that done refuses a plain file sitting where a worktree should be.
func TestTicketDoneFileIsNotWorktree(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	f.clone(t, filepath.Join(f.projects, "devzone"))
	wtDir := filepath.Join(f.projects, "devzone-wt")
	if err := os.MkdirAll(wtDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wtDir, "dz-6"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, errOut, code := runTicketArgs("done", "6")
	if code != 2 {
		t.Fatalf("ticket done 6 status = %d, want 2", code)
	}
	if !strings.Contains(errOut, "no worktree for ticket 6") {
		t.Errorf("error output = %q", errOut)
	}
}

// TestTicketDoneRemoveFailureKeepsStatus checks that a worktree git refuses to remove keeps its folder and status 128.
func TestTicketDoneRemoveFailureKeepsStatus(t *testing.T) {
	f := newTicketFixture(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	clone := filepath.Join(f.projects, "devzone")
	f.clone(t, clone)
	wt := filepath.Join(f.projects, "devzone-wt", "dz-558")
	if _, _, code := runTicketArgs("558"); code != 0 {
		t.Fatalf("ticket 558 status = %d, want 0", code)
	}
	testkit.Git(t, clone, "worktree", "lock", wt)

	_, _, code := runTicketArgs("done", "558")
	if code != 128 {
		t.Errorf("ticket done 558 status = %d, want 128", code)
	}
	if fi, err := os.Stat(wt); err != nil || !fi.IsDir() {
		t.Errorf("worktree %s is gone: %v", wt, err)
	}
}
