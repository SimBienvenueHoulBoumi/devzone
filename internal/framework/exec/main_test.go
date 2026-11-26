package exec

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// TestMain clears the repository variables before the runner tests run, so a
// hook cannot make a git command reach its own repository. It calls the helper
// directly: testkit imports this package's fake runner and would create a cycle.
func TestMain(m *testing.M) {
	os.Exit(testhygiene.Main(m))
}
