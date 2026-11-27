//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestPortsEnableStopsManualWatcherBeforeServiceStart checks that enable stops
// a watcher started by hand and waits for it before the service manager starts
// the managed one: only one watcher may own the state folder at a time.
func TestPortsEnableStopsManualWatcherBeforeServiceStart(t *testing.T) {
	h := newPortsEnableHarness(t)
	manual := h.manualWatcher()
	h.simulateRun = true
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable = %d, err = %q", code, errOut.String())
	}
	if alive(manual) {
		t.Fatal("enable left the manual watcher alive")
	}
	if h.loopCalls != 1 {
		t.Fatalf("service loop calls = %d, want 1", h.loopCalls)
	}
	if len(h.calls) != 1 || !hasArg(h.calls[0].args, "--now") {
		t.Fatalf("daemon calls = %v, want one enable --now", h.calls)
	}
}

// TestPortsStartUsesTheServiceWhenInstalled checks that a start after enable
// goes through the service manager, so the watcher stays managed.
func TestPortsStartUsesTheServiceWhenInstalled(t *testing.T) {
	h := newPortsEnableHarness(t)
	h.installAgent()
	h.simulateRun = true
	var out, errOut bytes.Buffer
	if code := PortsStart(&out, &errOut); code != 0 {
		t.Fatalf("start = %d, err = %q", code, errOut.String())
	}
	if len(h.calls) != 2 || !hasArg(h.calls[0].args, "is-active") || !hasArg(h.calls[1].args, "start") {
		t.Fatalf("daemon calls = %v, want a load check then one service start", h.calls)
	}
	if h.loopCalls != 1 {
		t.Fatalf("service loop calls = %d, want 1", h.loopCalls)
	}
	if pid := readPid(filepath.Join(h.stateDir, "pid")); pid != 0 {
		t.Fatalf("start left a manual pid %d", pid)
	}
}

// TestPortsStopManagedWatcherStaysStopped checks that stopping a managed
// watcher does not ask the service manager to start it again before the next
// start, enable or session.
func TestPortsStopManagedWatcherStaysStopped(t *testing.T) {
	h := newPortsEnableHarness(t)
	h.installAgent()
	managed := h.manualWatcher()
	if code := PortsStop(); code != 0 {
		t.Fatalf("stop = %d", code)
	}
	if alive(managed) {
		t.Fatal("the managed watcher was not stopped")
	}
	if len(h.calls) != 0 || h.loopCalls != 0 {
		t.Fatalf("stop relaunched the watcher: calls = %v, loops = %d", h.calls, h.loopCalls)
	}
	if pid := readPid(filepath.Join(h.stateDir, "pid")); pid != 0 {
		t.Fatalf("stop left pid %d", pid)
	}
}

// installAgent writes the definition of this instance without starting a
// watcher, so a start or stop sees an installed automatic start.
func (h *portsEnableHarness) installAgent() {
	h.t.Helper()
	name := portsAgentName() + "." + portsAgentExt()
	if err := os.MkdirAll(h.agentDir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(h.agentDir, name), []byte("definition\n"), 0o644); err != nil {
		h.t.Fatal(err)
	}
}

// TestPortsDisableUnloadsBeforeRemovingDefinition checks that the service
// manager can still see the unit or the agent when it is asked to disable it,
// and that systemd reloads before and after the file is removed.
func TestPortsDisableUnloadsBeforeRemovingDefinition(t *testing.T) {
	for _, tc := range []struct {
		platform string
		want     []bool
	}{
		{"linux", []bool{true, true, false}},
		{"darwin", []bool{true}},
	} {
		t.Run(tc.platform, func(t *testing.T) {
			h := newPortsEnableHarness(t)
			portsPlatform = tc.platform
			h.installAgent()
			var seen []bool
			portsDaemon = func(tool string, quiet bool, args ...string) int {
				seen = append(seen, portsAgentExists())
				return 0
			}
			var out, errOut bytes.Buffer
			if code := PortsDisable(&out, &errOut); code != 0 {
				t.Fatalf("disable = %d, err = %q", code, errOut.String())
			}
			if len(seen) != len(tc.want) {
				t.Fatalf("daemon calls = %d, want %d: %v", len(seen), len(tc.want), seen)
			}
			for i := range tc.want {
				if seen[i] != tc.want[i] {
					t.Fatalf("call %d saw definition %v, want %v", i, seen[i], tc.want[i])
				}
			}
			if portsAgentExists() {
				t.Fatal("disable left the definition")
			}
		})
	}
}

// TestPortsDisableKeepsDefinitionWhenSystemdRefuses checks that a failed
// disable leaves the unit in place so the user can retry.
func TestPortsDisableKeepsDefinitionWhenSystemdRefuses(t *testing.T) {
	h := newPortsEnableHarness(t)
	h.installAgent()
	h.daemonCode = 5
	var out, errOut bytes.Buffer
	if code := PortsDisable(&out, &errOut); code != 5 {
		t.Fatalf("disable = %d, err = %q", code, errOut.String())
	}
	if !portsAgentExists() {
		t.Fatal("a failed disable removed the definition")
	}
}
