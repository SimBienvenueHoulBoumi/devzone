package catalog

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// TestMain runs the catalog tests without the machine's kubeconfig and with
// failing kubectl and helm stand-ins ahead of the real tools in the PATH.
func TestMain(m *testing.M) {
	os.Exit(testhygiene.Main(m))
}
