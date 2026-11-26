package checks

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// initCheckRepo creates a throwaway repository with one tracked code file.
func initCheckRepo(t *testing.T, dir, file string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, file), []byte("package p\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testhygiene.Git(t, dir, "init", "-q")
	testhygiene.Git(t, dir, "add", "-A")
	testhygiene.Git(t, dir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "depart")
}

// TestGitCommandsIgnoreInheritedGitDir checks that the English check uses the
// folder under test even when GIT_DIR names another repository.
func TestGitCommandsIgnoreInheritedGitDir(t *testing.T) {
	testhygiene.RequireGit(t)
	root := t.TempDir()
	target := filepath.Join(root, "target")
	decoy := filepath.Join(root, "decoy")
	initCheckRepo(t, target, "tool.go")
	initCheckRepo(t, decoy, "other.go")
	t.Chdir(target)
	t.Setenv("GIT_DIR", filepath.Join(decoy, ".git"))
	t.Setenv("GIT_WORK_TREE", decoy)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(decoy, ".git", "index"))

	gotRoot, err := RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	wantRoot, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatal(err)
	}
	if gotRoot != wantRoot {
		t.Errorf("repo root = %s, want %s", gotRoot, wantRoot)
	}
	files, err := trackedFiles(target)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0] != "tool.go" {
		t.Fatalf("tracked files = %v, want [tool.go]", files)
	}
}
