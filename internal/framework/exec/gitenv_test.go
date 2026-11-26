package exec

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// initRunnerRepo creates a throwaway repository with one commit for the runner
// test, using the shared helper so a hook cannot redirect it.
func initRunnerRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	testhygiene.Git(t, dir, "init", "-q")
	testhygiene.Git(t, dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "depart", "--allow-empty")
}

// TestExecRunnerIgnoresInheritedGitDir checks that a git command aimed at one
// folder stays there when the environment names another repository.
func TestExecRunnerIgnoresInheritedGitDir(t *testing.T) {
	testhygiene.RequireGit(t)
	root := t.TempDir()
	target := filepath.Join(root, "target")
	decoy := filepath.Join(root, "decoy")
	initRunnerRepo(t, target)
	initRunnerRepo(t, decoy)
	inherited := []string{
		"GIT_DIR=" + filepath.Join(decoy, ".git"),
		"GIT_WORK_TREE=" + decoy,
		"GIT_INDEX_FILE=" + filepath.Join(decoy, ".git", "index"),
	}
	r := ExecRunner{}
	res, err := r.Run(context.Background(), "git",
		[]string{"-C", target, "rev-parse", "--absolute-git-dir"}, Opts{Env: inherited})
	if err != nil || res.Code != 0 {
		t.Fatalf("git rev-parse: %v, code %d, %s", err, res.Code, res.Stderr)
	}
	gotDir, err := filepath.EvalSymlinks(strings.TrimSpace(string(res.Stdout)))
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

	res, err = r.Run(context.Background(), "git", []string{"-C", target,
		"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "own", "--allow-empty"},
		Opts{Env: inherited})
	if err != nil || res.Code != 0 {
		t.Fatalf("git commit: %v, code %d, %s", err, res.Code, res.Stderr)
	}
	if got := testhygiene.Git(t, decoy, "rev-list", "--count", "HEAD"); got != "1" {
		t.Errorf("decoy commits = %s, want 1", got)
	}
	if got := testhygiene.Git(t, target, "rev-list", "--count", "HEAD"); got != "2" {
		t.Errorf("target commits = %s, want 2", got)
	}
}
