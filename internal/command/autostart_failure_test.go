package command

import (
	"bytes"
	"testing"
)

// TestEnsureStopsAfterAutoStartFailure checks that a remembered failure of the
// service manager stops every automatic attempt, without touching the refusal
// the user may have chosen, and that the explicit enable is not involved.
func TestEnsureStopsAfterAutoStartFailure(t *testing.T) {
	h := newAutoStartHarness(t)
	old := commandPortsAutoStartFailed
	t.Cleanup(func() { commandPortsAutoStartFailed = old })
	commandPortsAutoStartFailed = func() bool { return true }
	var out, errOut bytes.Buffer
	EnsurePortsAutoStart(&out, &errOut)
	if h.enableCalls != 0 || out.Len() != 0 || errOut.Len() != 0 {
		t.Fatalf("enable calls = %d, out = %q, err = %q", h.enableCalls, out.String(), errOut.String())
	}
}
