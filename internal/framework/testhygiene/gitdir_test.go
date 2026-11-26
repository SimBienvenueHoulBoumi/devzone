package testhygiene

import (
	"os"
	osExec "os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/gitenv"
)

// TestMain isolates the helper's own tests from a hook's repository.
func TestMain(m *testing.M) {
	os.Exit(Main(m))
}

// initDecoy creates a throwaway repository with one commit. The environment is
// cleaned so a hook that started the suite cannot redirect the initialization.
func initDecoy(t *testing.T, root, name string) string {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"init", "-q"},
		{"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "depart", "--allow-empty"},
	} {
		cmd := osExec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(gitenv.Clean(os.Environ()), "GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
		}
	}
	return dir
}

// hookEnv returns the variables a hook exports, pointing at the decoy repo.
func hookEnv(decoy string) []string {
	return append(gitenv.Clean(os.Environ()),
		"GIT_DIR="+filepath.Join(decoy, ".git"),
		"GIT_WORK_TREE="+decoy,
		"GIT_INDEX_FILE="+filepath.Join(decoy, ".git", "index"))
}

// TestInheritedGitDirDivertsGitMinusC shows on two throwaway repositories that
// a commit aimed at one folder is written to the repository named by GIT_DIR.
func TestInheritedGitDirDivertsGitMinusC(t *testing.T) {
	RequireGit(t)
	root := t.TempDir()
	decoy := initDecoy(t, root, "decoy")
	target := initDecoy(t, root, "target")

	probe := osExec.Command("git", "-C", target, "rev-parse", "--absolute-git-dir")
	probe.Env = hookEnv(decoy)
	out, err := probe.Output()
	if err != nil {
		t.Fatal(err)
	}
	wantDir, err := filepath.EvalSymlinks(filepath.Join(decoy, ".git"))
	if err != nil {
		t.Fatal(err)
	}
	gotDir, err := filepath.EvalSymlinks(strings.TrimSpace(string(out)))
	if err != nil {
		t.Fatal(err)
	}
	if gotDir != wantDir {
		t.Fatalf("git dir = %s, want the decoy %s", gotDir, wantDir)
	}

	commit := osExec.Command("git", append([]string{"-C", target, "-c", "user.name=t",
		"-c", "user.email=t@t", "commit", "-qm", "pirate", "--allow-empty"})...)
	commit.Env = hookEnv(decoy)
	if out, err := commit.CombinedOutput(); err != nil {
		t.Fatalf("diverted commit: %v\n%s", err, out)
	}
	if got := Git(t, decoy, "rev-list", "--count", "HEAD"); got != "2" {
		t.Errorf("decoy commits = %s, want 2: the commit did not reach GIT_DIR", got)
	}
	if got := Git(t, target, "rev-list", "--count", "HEAD"); got != "1" {
		t.Errorf("target commits = %s, want 1: the commit did not stay in the decoy", got)
	}
}

// TestGitHelperReachesItsOwnFolder checks that the shared helper removes the
// inherited variables before running the same commit against its own folder.
func TestGitHelperReachesItsOwnFolder(t *testing.T) {
	root := t.TempDir()
	decoy := initDecoy(t, root, "decoy")
	target := initDecoy(t, root, "target")
	t.Setenv("GIT_DIR", filepath.Join(decoy, ".git"))
	t.Setenv("GIT_WORK_TREE", decoy)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(decoy, ".git", "index"))

	Git(t, target, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "own", "--allow-empty")
	if got := Git(t, target, "rev-list", "--count", "HEAD"); got != "2" {
		t.Errorf("target commits = %s, want 2", got)
	}
	if got := Git(t, decoy, "rev-list", "--count", "HEAD"); got != "1" {
		t.Errorf("decoy commits = %s, want 1", got)
	}
}
