//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// failingHarness returns a harness whose service manager refuses every call
// with status 7, in a devzone folder that exists so the failure marker can be
// written there.
func failingHarness(t *testing.T, platform string) *portsEnableHarness {
	t.Helper()
	h := newPortsEnableHarness(t)
	portsPlatform = platform
	if err := os.MkdirAll(os.Getenv("DEVZONE_ROOT"), 0o755); err != nil {
		t.Fatal(err)
	}
	h.daemonCode = 7
	return h
}

// fakeWatcherLaunch replaces the launch of the watcher by hand with a real
// sleep process, which the test stops at its end. It returns the pids started.
func fakeWatcherLaunch(t *testing.T) *[]int {
	t.Helper()
	launched := &[]int{}
	old := portsWatcherLauncher
	t.Cleanup(func() { portsWatcherLauncher = old })
	portsWatcherLauncher = func(string) (int, error) {
		pid, done := startSleep(t)
		*launched = append(*launched, pid)
		t.Cleanup(func() {
			if alive(pid) {
				terminate(pid)
				waitExit(t, done)
			}
		})
		return pid, nil
	}
	return launched
}

// TestPortsEnableFailureRestoresManualWatcher checks that a refused definition
// leaves no faulty file, starts the manual watcher again, prints one warning
// line and remembers the failure apart from a user refusal.
func TestPortsEnableFailureRestoresManualWatcher(t *testing.T) {
	for _, platform := range []string{"linux", "darwin"} {
		t.Run(platform, func(t *testing.T) {
			h := failingHarness(t, platform)
			old := h.manualWatcher()
			launched := fakeWatcherLaunch(t)
			var out, errOut bytes.Buffer
			if code := PortsEnable(&out, &errOut); code != 1 {
				t.Fatalf("status = %d, err = %q", code, errOut.String())
			}
			if alive(old) {
				t.Fatal("enable left the manual watcher running")
			}
			if len(*launched) != 1 {
				t.Fatalf("manual watcher launches = %d, want 1", len(*launched))
			}
			pid := (*launched)[0]
			if readPid(filepath.Join(h.stateDir, "pid")) != pid || !alive(pid) {
				t.Fatalf("state pid does not hold the restarted watcher %d", pid)
			}
			if portsAgentExists() {
				t.Fatal("the refused definition was kept")
			}
			if PortsRefused() {
				t.Fatal("a service manager failure was recorded as a user refusal")
			}
			if !PortsAutoStartFailed() {
				t.Fatal("the failure was not remembered")
			}
			warning := errOut.String()
			if strings.Count(warning, "\n") != 1 || !strings.HasPrefix(warning, "⚠ ") || !strings.Contains(warning, "status 7") {
				t.Fatalf("warning = %q, want one warning line with the status", warning)
			}
			if strings.Contains(out.String(), "enabled") {
				t.Fatalf("success on failure: %q", out.String())
			}
		})
	}
}

// TestPortsEnableFailureEndsWithProgramChange checks that the failure marker
// holds while the program is the same, and that a changed program or a
// successful explicit enable removes it.
func TestPortsEnableFailureEndsWithProgramChange(t *testing.T) {
	h := failingHarness(t, "linux")
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 1 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if !PortsAutoStartFailed() {
		t.Fatal("the failure was not remembered")
	}
	h.writeBinary("binary v2\n")
	if PortsAutoStartFailed() {
		t.Fatal("a changed program is still suppressed")
	}
	h.daemonCode = 0
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable = %d, err = %q", code, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(os.Getenv("DEVZONE_ROOT"), portsFailureName)); !os.IsNotExist(err) {
		t.Fatalf("a successful enable kept the failure marker: %v", err)
	}
}
