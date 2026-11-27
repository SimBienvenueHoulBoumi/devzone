//go:build !windows

package workspace

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// enableWindowsForTest puts the harness on the Windows branch and installs the
// automatic start there, through the fake schtasks only. It returns the name of
// the task and the path of its XML file, and clears the recorded calls so that
// each test sees only the calls it makes itself.
func enableWindowsForTest(t *testing.T, h *portsEnableHarness) (string, string) {
	t.Helper()
	portsPlatform = "windows"
	t.Setenv("USERDOMAIN", "CORP")
	t.Setenv("USERNAME", "sim")
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable status = %d, err %q", code, errOut.String())
	}
	h.calls = nil
	return portsAgentName(), filepath.Join(h.agentDir, portsAgentName()+".xml")
}

// TestPortsEnableWindowsCreatesTask checks the Windows automatic start with the
// fake service manager: schtasks creates the task from the XML of the agent
// folder, then runs it at once. The watcher copy keeps the .exe extension.
func TestPortsEnableWindowsCreatesTask(t *testing.T) {
	h := newPortsEnableHarness(t)
	portsPlatform = "windows"
	t.Setenv("USERDOMAIN", "CORP")
	t.Setenv("USERNAME", "sim")
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable status = %d, err %q", code, errOut.String())
	}
	name := portsAgentName()
	xmlPath := filepath.Join(h.agentDir, name+".xml")
	want := []portsDaemonCall{
		{tool: "schtasks", args: []string{"/Create", "/TN", name, "/XML", xmlPath, "/F"}},
		{tool: "schtasks", args: []string{"/Run", "/TN", name}},
	}
	if !sameCalls(h.calls, want) {
		t.Fatalf("calls = %+v, want %+v", h.calls, want)
	}
	data, err := os.ReadFile(xmlPath)
	if err != nil {
		t.Fatalf("task file not written: %v", err)
	}
	if text := decodeTaskFile(t, data); !strings.Contains(text, "<UserId>CORP\\sim</UserId>") {
		t.Fatalf("task file does not name the user:\n%s", text)
	}
	if !strings.HasSuffix(portsWatcherCopyPath(), "devzone.exe") || !exists(portsWatcherCopyPath()) {
		t.Fatalf("watcher copy %q is missing or has no .exe extension", portsWatcherCopyPath())
	}
	if !strings.Contains(out.String(), "automatic start enabled") {
		t.Fatalf("out = %q", out.String())
	}
}

// TestPortsEnableWindowsFailureStops checks that a refused task creation stops
// the enable with status 1, that no run is attempted, and that the failure is
// rolled back: the task is deleted again and its file removed.
func TestPortsEnableWindowsFailureStops(t *testing.T) {
	h := newPortsEnableHarness(t)
	portsPlatform = "windows"
	h.daemonCode = 1
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 1 {
		t.Fatalf("enable status = %d", code)
	}
	name := portsAgentName()
	if len(h.calls) != 2 || !sameCalls(h.calls[:1], []portsDaemonCall{{tool: "schtasks",
		args: []string{"/Create", "/TN", name, "/XML", filepath.Join(h.agentDir, name+".xml"), "/F"}}}) ||
		h.calls[1].args[0] != "/Delete" {
		t.Fatalf("calls = %+v, want the creation then the rollback", h.calls)
	}
	if exists(filepath.Join(h.agentDir, name+".xml")) {
		t.Fatal("the failed enable left its task file")
	}
	if !strings.Contains(errOut.String(), "not enabled") {
		t.Fatalf("err = %q", errOut.String())
	}
}

// TestPortsDisableWindowsDeletesTask checks that disable deletes the task and
// removes its file, so the scheduler no longer relaunches the watcher.
func TestPortsDisableWindowsDeletesTask(t *testing.T) {
	h := newPortsEnableHarness(t)
	name, xmlPath := enableWindowsForTest(t, h)
	var out, errOut bytes.Buffer
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatalf("disable status = %d, err %q", code, errOut.String())
	}
	want := []portsDaemonCall{{tool: "schtasks", args: []string{"/Delete", "/TN", name, "/F"}}}
	if !sameCalls(h.calls, want) {
		t.Fatalf("calls = %+v, want %+v", h.calls, want)
	}
	if exists(xmlPath) {
		t.Fatal("disable left the task file")
	}
	if !strings.Contains(out.String(), "automatic start disabled") {
		t.Fatalf("out = %q", out.String())
	}
}

// TestPortsDisableWindowsMissingTask checks that a task already gone is not an
// error: the file is removed and disable still succeeds, so it can be repeated.
func TestPortsDisableWindowsMissingTask(t *testing.T) {
	h := newPortsEnableHarness(t)
	_, xmlPath := enableWindowsForTest(t, h)
	h.daemonCode = 1
	var out, errOut bytes.Buffer
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatalf("disable status = %d, err %q", code, errOut.String())
	}
	if exists(xmlPath) {
		t.Fatal("disable kept the task file although the task was missing")
	}
}

// TestPortsStartWindowsRunsTask checks that ports start runs the installed task
// through schtasks /Run when no watcher is alive.
func TestPortsStartWindowsRunsTask(t *testing.T) {
	h := newPortsEnableHarness(t)
	name, _ := enableWindowsForTest(t, h)
	var out, errOut bytes.Buffer
	if code := PortsStart(&out, &errOut); code != 0 {
		t.Fatalf("start status = %d, err %q", code, errOut.String())
	}
	want := []portsDaemonCall{
		{tool: "schtasks", quiet: true, args: []string{"/Query", "/TN", name}},
		{tool: "schtasks", args: []string{"/Run", "/TN", name}},
	}
	if !sameCalls(h.calls, want) {
		t.Fatalf("calls = %+v, want %+v", h.calls, want)
	}
}

// TestPortsStartWindowsKeepsLiveWatcher checks that ports start does not ask the
// scheduler for a second run while a watcher is alive: the live one is kept.
func TestPortsStartWindowsKeepsLiveWatcher(t *testing.T) {
	h := newPortsEnableHarness(t)
	enableWindowsForTest(t, h)
	h.manualWatcher()
	var out, errOut bytes.Buffer
	if code := PortsStart(&out, &errOut); code != 0 {
		t.Fatalf("start status = %d", code)
	}
	if len(h.calls) != 1 || h.calls[0].args[0] != "/Query" || !strings.Contains(out.String(), "already running") {
		t.Fatalf("calls = %+v, out = %q", h.calls, out.String())
	}
}

// TestPortsAgentRunWindowsRuns checks that the task command runs the watcher
// loop on Windows, where it used to be refused before #903. The loop is replaced by
// a counter, so no real watcher starts.
func TestPortsAgentRunWindowsRuns(t *testing.T) {
	h := newPortsEnableHarness(t)
	portsPlatform = "windows"
	var errOut bytes.Buffer
	if code := PortsAgentRun(io.Discard, &errOut); code != 0 {
		t.Fatalf("agent status = %d, err %q", code, errOut.String())
	}
	if h.loopCalls != 1 || errOut.Len() != 0 {
		t.Fatalf("loop calls = %d, err %q", h.loopCalls, errOut.String())
	}
}

// sameCalls reports whether two lists of service manager calls hold the same
// tools and arguments in the same order.
func sameCalls(got, want []portsDaemonCall) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i].tool != want[i].tool || strings.Join(got[i].args, " ") != strings.Join(want[i].args, " ") {
			return false
		}
	}
	return true
}
