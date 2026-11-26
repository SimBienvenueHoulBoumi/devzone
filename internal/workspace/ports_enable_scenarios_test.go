//go:build !windows

package workspace

import (
	"bytes"
	"io"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsEnableNeverDoublesAManualWatcher checks that the agent started by
// the service manager sees no watcher started by hand: enable stopped it first.
func TestPortsEnableNeverDoublesAManualWatcher(t *testing.T) {
	h := newPortsEnableHarness(t)
	pid := h.manualWatcher()
	h.simulateRun = true
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if h.loopCalls != 1 || alive(pid) {
		t.Fatalf("loop calls = %d, manual watcher alive = %v, want 1 and false", h.loopCalls, alive(pid))
	}
	if got := readPid(filepath.Join(h.stateDir, "pid")); got != 0 {
		t.Fatalf("enable left pid %d", got)
	}
}

// TestPortsStopThenReenable checks that a stopped watcher stays stopped and
// that the next enable stops the manual watcher again before the service starts
// the managed one.
func TestPortsStopThenReenable(t *testing.T) {
	h := newPortsEnableHarness(t)
	h.simulateRun = true
	first := h.manualWatcher()
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if alive(first) {
		t.Fatal("the watcher was not stopped")
	}
	second := h.manualWatcher()
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if alive(second) || h.loopCalls != 2 || len(h.calls) < 2 {
		t.Fatalf("second alive = %v, loops = %d, daemon calls = %d", alive(second), h.loopCalls, len(h.calls))
	}
}

// TestPortsAutomaticStartGuardUnderBats keeps a test from loading a real
// service manager or starting a watcher, even when it calls enable directly.
func TestPortsAutomaticStartGuardUnderBats(t *testing.T) {
	h := newPortsEnableHarness(t)
	t.Setenv("BATS_TEST_TMPDIR", t.TempDir())
	t.Setenv("DEVZONE_PORTS_WORKSPACE_REAL", "")
	for _, run := range []func(io.Writer, io.Writer) int{PortsEnable, PortsDisable, PortsAgentRun} {
		var out, errOut bytes.Buffer
		if code := run(&out, &errOut); code != 0 {
			t.Fatalf("status = %d", code)
		}
		if !strings.Contains(errOut.String(), "refused under bats") || len(h.calls) != 0 || h.loopCalls != 0 {
			t.Fatalf("err = %q, calls = %v, loops = %d", errOut.String(), h.calls, h.loopCalls)
		}
	}
	if exists(h.agentDir) || exists(h.copyPath) {
		t.Fatal("the guard wrote files")
	}
}

// TestPortsEnableDisableSanitisedInstance keeps enable and disable symmetric when
// the instance name must be hashed before it can name a definition.
func TestPortsEnableDisableSanitisedInstance(t *testing.T) {
	h := newPortsEnableHarness(t)
	t.Setenv("DEVZONE_INSTANCE", "team/a")
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	definition := filepath.Join(h.agentDir, portsAgentName()+".service")
	if !exists(definition) {
		t.Fatalf("definition %q was not written", definition)
	}
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if exists(definition) {
		t.Fatal("disable left the definition of team/a")
	}
}
