package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// initTicketRepo creates a throwaway repository with one commit for gitCmd.
func initTicketRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	testhygiene.Git(t, dir, "init", "-q")
	testhygiene.Git(t, dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "depart", "--allow-empty")
}

// TestGitCmdIgnoresInheritedGitDir checks that the ticket command reaches the
// worktree it was given when a hook exported another repository.
func TestGitCmdIgnoresInheritedGitDir(t *testing.T) {
	testhygiene.RequireGit(t)
	root := t.TempDir()
	target := filepath.Join(root, "target")
	decoy := filepath.Join(root, "decoy")
	initTicketRepo(t, target)
	initTicketRepo(t, decoy)
	t.Setenv("GIT_DIR", filepath.Join(decoy, ".git"))
	t.Setenv("GIT_WORK_TREE", decoy)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(decoy, ".git", "index"))

	var errOut bytes.Buffer
	out, code := gitCmd(target, &errOut, "rev-parse", "--absolute-git-dir")
	if code != 0 {
		t.Fatalf("git rev-parse status = %d, output %q", code, errOut.String())
	}
	gotDir, err := filepath.EvalSymlinks(out)
	if err != nil {
		t.Fatal(err)
	}
	wantDir, err := filepath.EvalSymlinks(filepath.Join(target, ".git"))
	if err != nil {
		t.Fatal(err)
	}
	if gotDir != wantDir {
		t.Fatalf("git dir = %s, want %s", gotDir, wantDir)
	}

	_, code = gitCmd(target, &errOut, "-c", "user.name=t", "-c", "user.email=t@t",
		"commit", "-qm", "own", "--allow-empty")
	if code != 0 {
		t.Fatalf("git commit status = %d, output %q", code, errOut.String())
	}
	if got := testhygiene.Git(t, decoy, "rev-list", "--count", "HEAD"); got != "1" {
		t.Errorf("decoy commits = %s, want 1", got)
	}
	if got := strings.TrimSpace(testhygiene.Git(t, target, "rev-list", "--count", "HEAD")); got != "2" {
		t.Errorf("target commits = %s, want 2", got)
	}
}
