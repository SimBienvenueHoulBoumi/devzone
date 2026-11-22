//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// bashStart runs ports_start of the original script, sourced, with the state
// folder dir, and returns its two streams and its status.
func (le *liveEnv) bashStart(dir string) (string, string, int) {
	le.t.Helper()
	script, err := filepath.Abs(filepath.FromSlash(portsScript))
	if err != nil {
		le.t.Fatal(err)
	}
	cmd := exec.Command("bash", "-c", `. "$1"; ports_start`, "_", script)
	var out, errOut bytes.Buffer
	cmd.Dir, cmd.Stdout, cmd.Stderr = le.h.dir, &out, &errOut
	cmd.Env = append(os.Environ(), "DEVZONE_PORTS_WORKSPACE_DIR="+dir)
	code := 0
	if err := cmd.Run(); err != nil {
		code = 1
	}
	return out.String(), errOut.String(), code
}

// bashWatcher starts the bash watcher ("bash ports-workspace.sh loop") the way
// the user would have, records its pid and returns it.
func (le *liveEnv) bashWatcher(dir string) int {
	le.t.Helper()
	script, err := filepath.Abs(filepath.FromSlash(portsScript))
	if err != nil {
		le.t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "lock"), 0o755); err != nil {
		le.t.Fatal(err)
	}
	cmd := exec.Command("bash", script, "loop")
	cmd.Dir = le.h.dir
	pid, err := startDetached(cmd)
	if err != nil {
		le.t.Fatal(err)
	}
	le.roots = append(le.roots, pid)
	writeFile(le.t, filepath.Join(dir, "pid"), strconv.Itoa(pid)+"\n")
	return pid
}

// TestPortsStartSameMessagesAsBash compares what the shell and the Go code
// print, on both streams and with the same status, for a start.
func TestPortsStartSameMessagesAsBash(t *testing.T) {
	le := newLiveEnv(t)
	shDir := le.state("sh")
	shOut, shErr, shCode := le.bashStart(shDir)
	goDir := le.state("go")
	goOut, goErr, goCode := le.start()
	norm := func(s, dir string) string { return strings.ReplaceAll(s, dir, "<dir>") }
	if norm(shOut, shDir) != norm(goOut, goDir) || shErr != goErr || shCode != goCode {
		t.Fatalf("bash: %q %q %d\nGo:   %q %q %d", shOut, shErr, shCode, goOut, goErr, goCode)
	}
	if !strings.HasPrefix(goOut, "Workspace ports: watcher started, log ") {
		t.Fatalf("not a start: %q", goOut)
	}
	for _, d := range []string{shDir, goDir} {
		for _, name := range []string{"pid", "lock", "journal.log"} {
			if !exists(filepath.Join(d, name)) {
				t.Errorf("%s misses %s", d, name)
			}
		}
		le.relayPid(d)
	}
}

// TestPortsStartAlreadyRunningSameAsBash: a bash watcher is running; the shell
// and the Go start both answer the same line with its pid.
func TestPortsStartAlreadyRunningSameAsBash(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	pid := le.bashWatcher(dir)
	waitFor(t, "the bash watcher", func() bool { return liveProc(pid) })
	shOut, shErr, shCode := le.bashStart(dir)
	goOut, goErr, goCode := le.start()
	want := "Workspace ports: watcher already running (pid " + strconv.Itoa(pid) + ")\n"
	if shOut != want || goOut != want || shErr != goErr || shCode != goCode {
		t.Fatalf("bash: %q %q %d\nGo:   %q %q %d\nwant %q", shOut, shErr, shCode, goOut, goErr, goCode, want)
	}
}

// TestPortsStartGuardSameAsBash: under bats both refuse with the same line on
// stderr, nothing on stdout, status 0.
func TestPortsStartGuardSameAsBash(t *testing.T) {
	le := newLiveEnv(t)
	t.Setenv("BATS_TEST_TMPDIR", t.TempDir())
	t.Setenv("DEVZONE_PORTS_WORKSPACE_REAL", "no")
	shDir := le.state("sh")
	shOut, shErr, shCode := le.bashStart(shDir)
	goOut, goErr, goCode := le.start()
	if shOut != goOut || shErr != goErr || shCode != goCode || goErr == "" {
		t.Fatalf("bash: %q %q %d\nGo:   %q %q %d", shOut, shErr, shCode, goOut, goErr, goCode)
	}
	if exists(shDir) {
		t.Error("the guard created the state folder")
	}
}

// TestBashWatcherSeenAndStoppedByGo: a watcher started by the shell is seen by
// the Go status (watcher line and relay) and stopped by the Go stop, which
// leaves no process, no pid, no lock and no relay.
func TestBashWatcherSeenAndStoppedByGo(t *testing.T) {
	le := newLiveEnv(t)
	dir := le.state("state")
	pid := le.bashWatcher(dir)
	relay := le.relayPid(dir)
	var out bytes.Buffer
	PortsStatus(&out)
	if !hasAll(out.String(), "Port watcher: running (pid "+strconv.Itoa(pid)+")\n", "  127.0.0.1:"+strconv.Itoa(le.port)+" relayed\n") {
		t.Fatalf("status: %q", out.String())
	}
	PortsStop()
	waitFor(t, "bash watcher and relay to be gone", func() bool { return !liveProc(pid) && !liveProc(relay) })
	for _, name := range []string{"pid", "lock"} {
		if exists(filepath.Join(dir, name)) {
			t.Errorf("%s left after stop", name)
		}
	}
	if left := stateNames(filepath.Join(dir, "relays")); len(left) != 0 {
		t.Errorf("relays left: %v", left)
	}
}
