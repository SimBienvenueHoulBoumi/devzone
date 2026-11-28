package command

import "testing"

// hostMode makes the host program behave as outside the pod so command routing
// tests stay hermetic when the suite runs in the pod (#980).
func hostMode(t *testing.T) {
	t.Helper()
	t.Setenv("DEVZONE_WORKSPACE", "")
}
