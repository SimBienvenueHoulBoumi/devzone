package agent

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestMain removes the variables that select a repository before the agent
// tests run, so a suite started by a hook cannot write to that repository.
func TestMain(m *testing.M) {
	os.Exit(testkit.Main(m))
}
