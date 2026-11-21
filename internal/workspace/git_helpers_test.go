package workspace

import (
	"os"
	"os/exec"
	"testing"
)

// gitEnv are the variables git sets for its hooks: inherited by a test run from a
// hook (pre-push), they make "git -C <dir>" act on the real repository instead of
// the temporary one.
var gitEnv = []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR"}

// requireGit skips the test when git is not installed, and removes the git hook
// variables from the environment of the test (restored when it ends)
func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	for _, name := range gitEnv {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
}

// runGit runs git in dir and fails the test on error
func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	full := append([]string{"-C", dir}, args...)
	if out, err := exec.Command("git", full...).CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}
