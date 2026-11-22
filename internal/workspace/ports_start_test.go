//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestPortsStartEndToEnd runs the real binary against a fake cluster: start,
// status, a second start and stop, and checks what the user sees and the
// processes behind it.
func TestPortsStartEndToEnd(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	want := "Workspace ports: watcher started, log " + dir + "/journal.log\n"
	if got := le.run("workspace", "ports", "start"); got != want {
		t.Fatalf("start printed %q, want %q", got, want)
	}
	pid := readPid(filepath.Join(dir, "pid"))
	if !liveProc(pid) {
		t.Fatalf("the watcher pid %d is not a live process", pid)
	}
	if !exists(filepath.Join(dir, "lock")) || !exists(filepath.Join(dir, "journal.log")) {
		t.Fatal("lock or journal.log is missing")
	}
	relay := le.relayPid(dir)
	status := le.run("workspace", "ports", "status")
	if !hasAll(status, "Port watcher: running (pid "+strconv.Itoa(pid)+")\n", "  127.0.0.1:"+strconv.Itoa(le.port)+" relayed\n") {
		t.Fatalf("status: %q", status)
	}
	again := "Workspace ports: watcher already running (pid " + strconv.Itoa(pid) + ")\n"
	if got := le.run("workspace", "ports", "start"); got != again {
		t.Fatalf("second start printed %q, want %q", got, again)
	}
	if got := readPid(filepath.Join(dir, "pid")); got != pid {
		t.Fatalf("the second start replaced the pid: %d, was %d", got, pid)
	}
	waitFor(t, "relay line in journal.log", func() bool {
		return strings.Contains(readAll(filepath.Join(dir, "journal.log")), "→ port "+strconv.Itoa(le.port)+" relayed on 127.0.0.1\n")
	})
	if got := le.run("workspace", "ports", "stop"); got != "" {
		t.Fatalf("stop printed %q", got)
	}
	waitFor(t, "watcher and relay to be gone", func() bool { return !liveProc(pid) && !liveProc(relay) })
	for _, name := range []string{"pid", "lock"} {
		if exists(filepath.Join(dir, name)) {
			t.Errorf("%s is still there after stop", name)
		}
	}
	if left := stateNames(filepath.Join(dir, "relays")); len(left) != 0 {
		t.Errorf("relays left: %v", left)
	}
	if got := le.run("workspace", "ports", "status"); !strings.HasPrefix(got, "Port watcher: stopped\n") {
		t.Errorf("status after stop: %q", got)
	}
}

// runLoop starts "workspace ports loop" in the foreground of the test, its
// output in the journal, and returns the command and the channel of its exit.
func (le *liveEnv) runLoop(dir string) (*exec.Cmd, chan error) {
	le.t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "lock"), 0o755); err != nil {
		le.t.Fatal(err)
	}
	journal, err := os.Create(filepath.Join(le.h.dir, "loop.log"))
	if err != nil {
		le.t.Fatal(err)
	}
	le.t.Cleanup(func() { _ = journal.Close() })
	cmd := exec.Command(le.bin, "workspace", "ports", "loop")
	cmd.Dir, cmd.Stdout, cmd.Stderr = le.h.dir, journal, journal
	if err := cmd.Start(); err != nil {
		le.t.Fatal(err)
	}
	le.roots = append(le.roots, cmd.Process.Pid)
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o644); err != nil {
		le.t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	return cmd, done
}

// TestPortsLoopStopsOnSigtermWithinTheStep sends SIGTERM during the 30 s pause
// between two rounds: the loop must leave at once with status 0 and clean up
// its relays, its lock and its pid.
func TestPortsLoopStopsOnSigtermWithinTheStep(t *testing.T) {
	le := newLiveEnv(t)
	t.Setenv("DEVZONE_PORTS_WORKSPACE_STEP", "30")
	dir := le.state("state")
	cmd, done := le.runLoop(dir)
	relay := le.relayPid(dir)
	began := time.Now()
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("exit: %v, want status 0", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the loop did not stop within 5 s of SIGTERM")
	}
	if d := time.Since(began); d > 3*time.Second {
		t.Fatalf("stop took %v, want under 3 s with a 30 s step", d)
	}
	waitFor(t, "the relay to be stopped", func() bool { return !liveProc(relay) })
	for _, name := range []string{"pid", "lock", filepath.Join("relays", strconv.Itoa(le.port))} {
		if exists(filepath.Join(dir, name)) {
			t.Errorf("%s is still there after SIGTERM", name)
		}
	}
}

// TestPortsLoopIgnoresSighup checks the nohup of the shell: the hangup of a
// closed terminal must not stop the watcher or its relay.
func TestPortsLoopIgnoresSighup(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	cmd, done := le.runLoop(dir)
	relay := le.relayPid(dir)
	if err := cmd.Process.Signal(syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		t.Fatalf("the loop stopped on SIGHUP: %v", err)
	case <-time.After(1500 * time.Millisecond):
	}
	if !liveProc(relay) || !exists(filepath.Join(dir, "lock")) {
		t.Fatal("SIGHUP disturbed the watcher")
	}
}

// TestPortsStartGuardUnderBats: under bats without the opt-in, only the
// refusal is printed, on the error output, and nothing is created.
func TestPortsStartGuardUnderBats(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	t.Setenv("BATS_TEST_TMPDIR", t.TempDir())
	for _, real := range []string{"", "no", "YES"} {
		t.Setenv("DEVZONE_PORTS_WORKSPACE_REAL", real)
		var out, errOut bytes.Buffer
		if code := PortsStart(&out, &errOut); code != 0 {
			t.Fatalf("REAL=%q: status %d", real, code)
		}
		if out.Len() != 0 || errOut.String() != "✖ port watcher refused under bats (DEVZONE_PORTS_WORKSPACE_REAL=yes required)\n" {
			t.Fatalf("REAL=%q: out %q err %q", real, out.String(), errOut.String())
		}
		if exists(dir) {
			t.Fatalf("REAL=%q: the guard created the state folder", real)
		}
	}
}
