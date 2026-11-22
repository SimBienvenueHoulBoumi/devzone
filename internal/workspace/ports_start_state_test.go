//go:build !windows

package workspace

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// start runs PortsStart in the test process (the watcher is the built binary).
func (le *liveEnv) start() (string, string, int) {
	le.t.Helper()
	le.useBinary()
	var out, errOut bytes.Buffer
	code := PortsStart(&out, &errOut)
	return out.String(), errOut.String(), code
}

// TestPortsStartRemovesRestartAndStaleLock: the signal left by the migration
// is removed, a stale lock folder (with a dead pid in pid) is replaced by a
// fresh one, the journal is appended to, not truncated, and the new pid is written.
func TestPortsStartRemovesRestartAndStaleLock(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	writeFile(t, filepath.Join(dir, "restart"), "")
	writeFile(t, filepath.Join(dir, "lock", "old"), "stale")
	writeFile(t, filepath.Join(dir, "pid"), "999999\n")
	writeFile(t, filepath.Join(dir, "journal.log"), "earlier line\n")
	out, errOut, code := le.start()
	if code != 0 || errOut != "" || !strings.HasPrefix(out, "Workspace ports: watcher started, log ") {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	if exists(filepath.Join(dir, "restart")) {
		t.Error("the restart signal is still there")
	}
	if !exists(filepath.Join(dir, "lock")) || exists(filepath.Join(dir, "lock", "old")) {
		t.Error("the lock is not a fresh folder")
	}
	pid := readPid(filepath.Join(dir, "pid"))
	if pid == 999999 || !liveProc(pid) {
		t.Errorf("pid %d is not the new live watcher", pid)
	}
	le.relayPid(dir)
	if !strings.HasPrefix(readAll(filepath.Join(dir, "journal.log")), "earlier line\n") {
		t.Error("the journal was truncated")
	}
}

// TestPortsStartAlreadyRunningKeepsState: even when a watcher runs,
// the restart signal goes (as the shell does before it looks at the pid), and
// nothing else changes.
func TestPortsStartAlreadyRunningKeepsState(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	pid, done := startSleep(t)
	defer func() { terminate(pid); waitExit(t, done) }()
	writeFile(t, filepath.Join(dir, "pid"), strconv.Itoa(pid)+"\n")
	writeFile(t, filepath.Join(dir, "restart"), "")
	out, _, code := le.start()
	if code != 0 || out != "Workspace ports: watcher already running (pid "+strconv.Itoa(pid)+")\n" {
		t.Fatalf("code %d out %q", code, out)
	}
	if exists(filepath.Join(dir, "restart")) || exists(filepath.Join(dir, "lock")) || exists(filepath.Join(dir, "journal.log")) {
		t.Error("restart should be gone, lock and journal.log never created")
	}
}

// TestPortsStartLockLostIsSilent: when the lock cannot be taken (the shell does
// "mkdir || return 0"), nothing is printed, no watcher starts, no pid is written.
func TestPortsStartLockLostIsSilent(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores folder permissions")
	}
	le := newLiveEnv(t)
	dir := le.state("state")
	writeFile(t, filepath.Join(dir, "lock", "x"), "")
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
	out, errOut, code := le.start()
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("code %d out %q err %q", code, out, errOut)
	}
	if exists(filepath.Join(dir, "pid")) || exists(filepath.Join(dir, "journal.log")) {
		t.Error("a watcher was started without the lock")
	}
}

// TestPortsStartLaunchFailureFreesTheLock: a watcher that cannot be launched is
// reported on the error output, and the lock is released so a later start can work.
func TestPortsStartLaunchFailureFreesTheLock(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	old := watcherExecutable
	watcherExecutable = func() (string, error) { return "", errors.New("no binary") }
	t.Cleanup(func() { watcherExecutable = old })
	var out, errOut bytes.Buffer
	if code := PortsStart(&out, &errOut); code != 1 || out.Len() != 0 || !strings.Contains(errOut.String(), "no binary") {
		t.Fatalf("code %d out %q err %q", code, out.String(), errOut.String())
	}
	if exists(filepath.Join(dir, "lock")) || exists(filepath.Join(dir, "pid")) {
		t.Error("lock or pid left behind")
	}
}
