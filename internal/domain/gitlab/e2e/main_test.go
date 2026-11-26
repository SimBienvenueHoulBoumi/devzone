package e2e

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestMain clears the repository variables before the end-to-end tests run,
// so their git clones cannot be redirected to a hook's repository.
func TestMain(m *testing.M) {
	os.Exit(testkit.Main(m))
}
