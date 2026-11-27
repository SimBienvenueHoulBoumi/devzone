package command

import (
	"os"
	"testing"
)

// TestMain removes the pod marker for the whole suite. The host program refuses
// to run in the pod (#980) and many tests call Run in-process; without this the
// suite fails in the pod, where the push hook runs it, and passes in CI. A test
// that needs the marker sets it itself with t.Setenv.
func TestMain(m *testing.M) {
	_ = os.Unsetenv("DEVZONE_WORKSPACE")
	os.Exit(m.Run())
}
