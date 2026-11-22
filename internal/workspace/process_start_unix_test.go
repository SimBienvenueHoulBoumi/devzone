//go:build !windows

package workspace

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestStartDetachedReapsExitedChild proves the reason of the Wait goroutine: a
// child that exits at once must stop being alive (kill -0) soon after, which
// only holds when it is collected. A zombie would make the next round believe
// the relay still runs.
func TestStartDetachedReapsExitedChild(t *testing.T) {
	pid, err := startDetached(exec.Command("true"))
	if err != nil {
		t.Skip("cannot run true:", err)
	}
	waitFor(t, "exited child to stop being alive", func() bool { return !alive(pid) })
}

// TestStartDetachedLeavesLiveChildAlone checks that a running child is alive, is
// the leader of its own session (Ctrl-C of the watcher does not reach it) and
// stops on SIGTERM, then disappears.
func TestStartDetachedLeavesLiveChildAlone(t *testing.T) {
	pid, err := startDetached(exec.Command("sleep", "600"))
	if err != nil {
		t.Skip("cannot run sleep:", err)
	}
	t.Cleanup(func() { terminate(pid) })
	time.Sleep(50 * time.Millisecond)
	if !alive(pid) {
		t.Fatal("child not alive")
	}
	if data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil {
		// fields after the command name: state, ppid, pgrp, session
		rest := strings.Fields(string(data)[strings.LastIndex(string(data), ") ")+2:])
		if rest[3] != strconv.Itoa(pid) {
			t.Fatalf("session %s, want its own %d", rest[3], pid)
		}
	}
	terminate(pid)
	waitFor(t, "terminated child to disappear", func() bool { return !alive(pid) })
}

// TestStartDetachedReportsStartError returns the error of a program that is missing.
func TestStartDetachedReportsStartError(t *testing.T) {
	if pid, err := startDetached(exec.Command("/nonexistent/devzone-relay")); err == nil || pid != 0 {
		t.Fatalf("pid %d err %v", pid, err)
	}
}
