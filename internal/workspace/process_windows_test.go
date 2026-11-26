//go:build windows

package workspace

import (
	"os"
	"os/exec"
	"testing"
	"time"
)

// TestWindowsProcessControl checks the Windows watcher process primitives with
// a short-lived helper that is this test binary itself: no port watcher, no
// kubectl and no network is started. The helper only sleeps, and the test
// terminates it as soon as it is known to be alive.
func TestWindowsProcessControl(t *testing.T) {
	if os.Getenv("DEVZONE_TEST_CHILD") == "1" {
		time.Sleep(10 * time.Second)
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestWindowsProcessControl$")
	cmd.Env = append(os.Environ(), "DEVZONE_TEST_CHILD=1")
	pid, err := startDetached(cmd)
	if err != nil {
		t.Fatalf("startDetached: %v", err)
	}
	if pid < 1 {
		t.Fatalf("startDetached returned pid %d", pid)
	}
	defer terminate(pid)
	if !alive(pid) {
		t.Fatalf("a just started helper (pid %d) is not alive", pid)
	}
	if alive(0) || alive(-1) {
		t.Fatal("a pid below 1 must never be alive")
	}
	terminate(pid)
	deadline := time.Now().Add(3 * time.Second)
	for alive(pid) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if alive(pid) {
		t.Fatalf("helper (pid %d) is still alive after terminate", pid)
	}
}

// TestWindowsStartDetachedError checks that a program that cannot start gives
// an error and no pid, so the watcher never records a relay that does not run.
func TestWindowsStartDetachedError(t *testing.T) {
	pid, err := startDetached(exec.Command("devzone-no-such-relay-program.exe"))
	if err == nil {
		t.Fatal("startDetached succeeded for a missing program")
	}
	if pid != 0 {
		t.Fatalf("startDetached returned pid %d for a missing program", pid)
	}
}
