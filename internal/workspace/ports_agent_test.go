//go:build !windows

package workspace

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsStatusReportsAutomaticStart reads the definition of this folder,
// then says whether the automatic start is enabled.
func TestPortsStatusReportsAutomaticStart(t *testing.T) {
	h := newPortsEnableHarness(t)
	if !strings.Contains(portsOut(t, h.stateDir), disabledWatcher) {
		t.Fatal("status says disabled without a definition")
	}
	label := portsAgentName()
	writeFile(t, filepath.Join(h.agentDir, label+".service"), "unit\n")
	got := portsOut(t, h.stateDir)
	if !strings.Contains(got, "Port watcher automatic start: enabled\n") {
		t.Fatalf("status = %q, want enabled", got)
	}
	if err := portsAgentRemove(h.agentDir, label); err != nil {
		t.Fatal(err)
	}
	if err := portsAgentRemove(h.agentDir, label); err != nil {
		t.Fatalf("second removal failed: %v", err)
	}
}
