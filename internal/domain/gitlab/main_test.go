package gitlab

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestMain clears the repository variables before the GitLab tests run: their
// commands must use their own folders even when a hook starts the suite.
func TestMain(m *testing.M) {
	os.Exit(testkit.Main(m))
}
