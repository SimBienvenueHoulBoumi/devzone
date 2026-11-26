package kube

import (
	"os"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testhygiene"
)

// TestMain runs the kube tests with a disposable home and failing Kubernetes
// tools ahead of the real ones in the PATH.
func TestMain(m *testing.M) {
	os.Exit(testhygiene.Main(m))
}
