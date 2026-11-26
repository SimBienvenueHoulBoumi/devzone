package checks

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestMain clears the repository variables before the checks tests run: the
// English check uses git, and a hook's GIT_DIR must never steer that command.
func TestMain(m *testing.M) {
	os.Exit(testkit.Main(m))
}
