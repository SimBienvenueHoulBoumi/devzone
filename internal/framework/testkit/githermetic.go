package testkit

import (
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// Main delegates to the shared hermetic environment helper, so callers of
// testkit get the same clean Git environment as every other package.
func Main(m *testing.M) int {
	return testhygiene.Main(m)
}

// RequireGit delegates to the shared helper to skip a test without git.
func RequireGit(t *testing.T) {
	t.Helper()
	testhygiene.RequireGit(t)
}

// Git delegates to the shared helper, which removes the variables that would
// redirect the command to another repository.
func Git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return testhygiene.Git(t, dir, args...)
}
