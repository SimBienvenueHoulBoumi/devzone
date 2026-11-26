// Package testhygiene provides the shared environment helpers used by tests
// that run git, kubectl or helm. It has no dependency on the runner packages,
// so even those can call it from TestMain.
package testhygiene

import (
	"os"
	osExec "os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/gitenv"
)

// Main runs a package's tests with a clean Git and Kubernetes environment: the
// variables that select a repository or a kubeconfig are removed, HOME plus the
// global Git config point at a disposable folder, and the PATH starts with
// failing stand-ins for kubectl and helm. A suite started by a hook cannot act
// on its repo or reach a cluster, and any direct tool call fails loudly.
func Main(m *testing.M) int {
	dir, err := os.MkdirTemp("", "devzone-test-home-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	for _, name := range gitenv.RepoVars {
		if err := os.Unsetenv(name); err != nil {
			panic(err)
		}
	}
	if err := os.Setenv("HOME", dir); err != nil {
		panic(err)
	}
	if err := os.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(dir, "gitconfig")); err != nil {
		panic(err)
	}
	if err := os.Setenv("GIT_CONFIG_NOSYSTEM", "1"); err != nil {
		panic(err)
	}
	if err := cleanKubeEnvironment(dir); err != nil {
		panic(err)
	}
	return m.Run()
}

// RequireGit skips the test when git is not installed, so suites stay runnable
// on a host without the binary.
func RequireGit(t *testing.T) {
	t.Helper()
	if _, err := osExec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
}

// Git runs git in dir, or in the current folder when dir is empty, after
// removing the variables that would redirect it to another repository. It
// fails the test on error and returns the trimmed combined output.
func Git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	RequireGit(t)
	if dir != "" {
		args = append([]string{"-C", dir}, args...)
	}
	cmd := osExec.Command("git", args...)
	cmd.Env = append(gitenv.Clean(os.Environ()), "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %q: %v\n%s", args, dir, err, out)
	}
	return strings.TrimSpace(string(out))
}
