package argocd

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestMain clears the repository variables before the platform Argo CD tests
// run, so a hook's repository cannot replace the folders used by those tests.
func TestMain(m *testing.M) {
	os.Exit(testkit.Main(m))
}
