//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// recordingDaemon replaces the service manager of a harness and remembers, for
// every call, which version of the watcher copy was on disk at that moment.
func recordingDaemon(h *portsEnableHarness, failRestart int) (*[]portsDaemonCall, *[]string) {
	calls := &[]portsDaemonCall{}
	binaries := &[]string{}
	portsDaemon = func(tool string, quiet bool, args ...string) int {
		*calls = append(*calls, portsDaemonCall{tool: tool, quiet: quiet, args: append([]string(nil), args...)})
		data, _ := os.ReadFile(h.copyPath)
		*binaries = append(*binaries, string(data))
		if failRestart != 0 && hasArg(args, "restart") {
			return failRestart
		}
		return 0
	}
	return calls, binaries
}

// TestPortsEnableRestartsAManagedWatcherOnReplacement checks with a fake service
// manager that a second enable asks Linux to restart the unit after the new
// binary is in place: enable --now alone leaves an active unit on the old one.
func TestPortsEnableRestartsAManagedWatcherOnReplacement(t *testing.T) {
	h := newPortsEnableHarness(t)
	calls, binaries := recordingDaemon(h, 0)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("first enable = %d, err = %q", code, errOut.String())
	}
	if len(*calls) != 1 {
		t.Fatalf("first enable made %d daemon calls, want one: %v", len(*calls), *calls)
	}

	h.writeBinary("binary v2\n")
	*calls, *binaries = nil, nil
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("second enable = %d, err = %q", code, errOut.String())
	}
	if len(*calls) != 2 || !hasArg((*calls)[0].args, "--now") || !hasArg((*calls)[1].args, "restart") {
		t.Fatalf("daemon calls = %v, want enable --now then restart", *calls)
	}
	if (*calls)[1].tool != "systemctl" {
		t.Fatalf("restart tool = %q", (*calls)[1].tool)
	}
	for i, binary := range *binaries {
		if binary != "binary v2\n" {
			t.Fatalf("daemon call %d saw copy %q, want the new program", i, binary)
		}
	}
}

// TestPortsEnableDoesNotRestartAnIdenticalWatcher checks that enabling twice
// with the same program neither rewrites the copy nor restarts the unit.
func TestPortsEnableDoesNotRestartAnIdenticalWatcher(t *testing.T) {
	h := newPortsEnableHarness(t)
	calls, _ := recordingDaemon(h, 0)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	*calls = nil
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if len(*calls) != 1 || hasArg((*calls)[0].args, "restart") {
		t.Fatalf("daemon calls = %v, want only enable --now", *calls)
	}
}

// TestPortsEnableDarwinReloadsInsteadOfRestarting checks that macOS needs no
// explicit restart: enable unloads the agent before loading it again.
func TestPortsEnableDarwinReloadsInsteadOfRestarting(t *testing.T) {
	h := newPortsEnableHarness(t)
	portsPlatform = "darwin"
	calls, _ := recordingDaemon(h, 0)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("first enable = %d, err = %q", code, errOut.String())
	}
	h.writeBinary("binary v2\n")
	*calls = nil
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("second enable = %d, err = %q", code, errOut.String())
	}
	if len(*calls) != 2 || hasArg((*calls)[0].args, "restart") || hasArg((*calls)[1].args, "restart") {
		t.Fatalf("daemon calls = %v, want bootout then bootstrap", *calls)
	}
	if !hasArg((*calls)[0].args, "bootout") || !hasArg((*calls)[1].args, "bootstrap") {
		t.Fatalf("daemon calls = %v, want bootout then bootstrap", *calls)
	}
}

// TestPortsEnableReportsRestartFailure checks that a failed explicit restart is
// reported instead of announcing that the new watcher is enabled.
func TestPortsEnableReportsRestartFailure(t *testing.T) {
	h := newPortsEnableHarness(t)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	_, _ = recordingDaemon(h, 9)
	h.writeBinary("binary v2\n")
	out.Reset()
	errOut.Reset()
	if code := PortsEnable(&out, &errOut); code != 1 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if !strings.Contains(errOut.String(), "not restarted") || !strings.Contains(errOut.String(), "status 9") {
		t.Fatalf("error = %q", errOut.String())
	}
	if strings.Contains(out.String(), "enabled") {
		t.Fatalf("success on failure: %q", out.String())
	}
}
