package podcmd

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestMain gives every pod command test a clean Git environment, so the
// throwaway repositories of the ticket fixtures are never replaced by a hook's.
func TestMain(m *testing.M) {
	os.Exit(testkit.Main(m))
}
