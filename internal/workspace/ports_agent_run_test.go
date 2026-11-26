//go:build !windows

package workspace

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestPortsAgentRunRunsOneLoop checks the foreground command of the automatic
// start: it owns the lock and the pid, writes its rounds to the journal and
// releases both when the loop returns.
func TestPortsAgentRunRunsOneLoop(t *testing.T) {
	h := newPortsEnableHarness(t)
	old := portsLoopRunner
	t.Cleanup(func() { portsLoopRunner = old })
	portsLoopRunner = func(out, _ io.Writer, _ time.Duration) int {
		_, _ = out.Write([]byte("round\n"))
		h.loopCalls++
		return 0
	}
	var out, errOut bytes.Buffer
	if code := PortsAgentRun(&out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if h.loopCalls != 1 {
		t.Fatalf("loop calls = %d, want 1", h.loopCalls)
	}
	data, err := os.ReadFile(filepath.Join(h.stateDir, "journal.log"))
	if err != nil || string(data) != "round\n" {
		t.Fatalf("journal = %q, err = %v", data, err)
	}
	if exists(filepath.Join(h.stateDir, "pid")) || exists(filepath.Join(h.stateDir, "lock")) {
		t.Fatal("agent left a pid or a lock")
	}
}

// TestPortsAgentRunLeavesAManualWatcherAlone checks that the agent never takes
// over the state of a watcher started by hand.
func TestPortsAgentRunLeavesAManualWatcherAlone(t *testing.T) {
	h := newPortsEnableHarness(t)
	pid := h.manualWatcher()
	var out, errOut bytes.Buffer
	if code := PortsAgentRun(&out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if h.loopCalls != 0 || readPid(filepath.Join(h.stateDir, "pid")) != pid {
		t.Fatalf("loop calls = %d, pid = %d", h.loopCalls, readPid(filepath.Join(h.stateDir, "pid")))
	}
	if !strings.Contains(out.String(), "already running") {
		t.Fatalf("out = %q", out.String())
	}
}

// TestPortsAgentRunClearsStaleLockAfterCrash starts the loop again when a hard
// shutdown left a lock and the pid of a watcher that is no longer alive.
func TestPortsAgentRunClearsStaleLockAfterCrash(t *testing.T) {
	h := newPortsEnableHarness(t)
	old := portsLoopRunner
	t.Cleanup(func() { portsLoopRunner = old })
	portsLoopRunner = func(io.Writer, io.Writer, time.Duration) int {
		h.loopCalls++
		return 0
	}
	pid, done := startSleep(t)
	terminate(pid)
	waitExit(t, done)
	writeFile(t, filepath.Join(h.stateDir, "pid"), strconv.Itoa(pid)+"\n")
	if err := os.Mkdir(filepath.Join(h.stateDir, "lock"), 0o755); err != nil {
		t.Fatal(err)
	}
	var out, errOut bytes.Buffer
	if code := PortsAgentRun(&out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if h.loopCalls != 1 {
		t.Fatalf("loop calls = %d, want 1", h.loopCalls)
	}
}
