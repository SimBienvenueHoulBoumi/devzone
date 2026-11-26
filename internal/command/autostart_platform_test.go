package command

import (
	"testing"
)

// TestWorkstationGateAcceptsWindows checks that a host outside any container is
// a workstation on every system, Windows included: the automatic start of the
// port watcher is installed there as a scheduled task (#903). The container
// variables are cleared so only the platform decides.
func TestWorkstationGateAcceptsWindows(t *testing.T) {
	for _, key := range containerEnvironmentVars {
		t.Setenv(key, "")
	}
	if !portsIsWorkstation() {
		t.Fatal("a host without a container or pod variable must be a workstation")
	}
}
