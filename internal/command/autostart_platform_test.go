package command

import (
	"runtime"
	"testing"
)

// TestWorkstationGateFollowsTheSystem checks that Windows is refused on Windows
// and that a plain Unix host is accepted, with no development container and no
// pod environment variable in the way.
func TestWorkstationGateFollowsTheSystem(t *testing.T) {
	for _, key := range containerEnvironmentVars {
		t.Setenv(key, "")
	}
	got := portsIsWorkstation()
	if runtime.GOOS == "windows" && got {
		t.Fatal("a Windows host must not be treated as a workstation for the watcher")
	}
	if runtime.GOOS != "windows" && !got {
		t.Fatal("a Unix host without a container or pod variable must be a workstation")
	}
}

// TestNoServiceManagerOnWindows checks that the Windows gate refuses before
// looking for a service manager, which does not exist there.
func TestNoServiceManagerOnWindows(t *testing.T) {
	got := portsServiceManagerAvailable()
	if runtime.GOOS == "windows" && got {
		t.Fatal("Windows has no service manager for the watcher")
	}
}
