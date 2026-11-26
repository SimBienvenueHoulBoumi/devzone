package workspace

import (
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// requireGit keeps the existing call sites: the shared helper skips the test
// when git is missing.
func requireGit(t *testing.T) {
	t.Helper()
	testkit.RequireGit(t)
}

// runGit runs git against the throwaway folder of a test through the shared
// helper, which removes the variables a hook may have exported.
func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	testkit.Git(t, dir, args...)
}
