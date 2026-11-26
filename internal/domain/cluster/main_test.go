package cluster

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// TestMain gives the cluster command tests a clean home, Git and Kubernetes
// environment, with failing stand-ins for the real tools.
func TestMain(m *testing.M) {
	os.Exit(testhygiene.Main(m))
}
