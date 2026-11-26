package workspace

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

// watcherExecutable gives the program that runs the watcher: this very binary.
// It is a variable so that a test can start a binary it has built, since the
// test binary itself does not know the "workspace ports loop" command.
var watcherExecutable = os.Executable

// PortsStart starts the port watcher of the workstation, as ports_start does,
// and only one: it exists so that the user types one command and the ports of
// the cluster are on localhost afterwards, without keeping a terminal busy.
//
// Under bats, without DEVZONE_PORTS_WORKSPACE_REAL=yes, it only prints a
// refusal on errOut (a test must never start a real watcher). Otherwise the
// state folder is created and the restart signal of the migration is removed;
// a live process in pid means the watcher already runs; else the lock is made
// by mkdir, which is atomic so that two simultaneous starts cannot both win (the
// loser prints nothing), the watcher is started detached and its pid written.
// The status is 0 in every case the shell returns 0, which is all of them.
func PortsStart(out, errOut io.Writer) int {
	if os.Getenv("BATS_TEST_TMPDIR") != "" && os.Getenv("DEVZONE_PORTS_WORKSPACE_REAL") != "yes" {
		fmt.Fprintln(errOut, "✖ port watcher refused under bats (DEVZONE_PORTS_WORKSPACE_REAL=yes required)")
		return 0
	}
	if portsAgentExists() {
		return portsStartService(out, errOut)
	}
	dir := portsDir()
	_ = os.MkdirAll(dir, 0o755)
	trimJournal(dir)
	_ = os.Remove(filepath.Join(dir, "restart"))
	if pid := readPid(filepath.Join(dir, "pid")); alive(pid) {
		fmt.Fprintf(out, "Workspace ports: watcher already running (pid %d)\n", pid)
		return 0
	}
	lock := filepath.Join(dir, "lock")
	_ = os.RemoveAll(lock)
	if err := os.Mkdir(lock, 0o755); err != nil {
		return 0
	}
	pid, err := launchWatcher(dir)
	if err != nil {
		// The shell cannot fail here; without the lock removed, no start could ever succeed.
		_ = os.Remove(lock)
		fmt.Fprintf(errOut, "✖ port watcher not started: %v\n", err)
		return 1
	}
	_ = os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644)
	fmt.Fprintf(out, "Workspace ports: watcher started, log %s/journal.log\n", dir)
	return 0
}

// portsStartService starts the watcher through the service manager that owns it
// when the automatic start is installed. On macOS a loaded job is kickstarted;
// bootstrap is the fallback for one that is not loaded. The manager, not this
// command, keeps the watcher and relaunches it after an abnormal exit.
func portsStartService(out, errOut io.Writer) int {
	tool := portsDaemonTool()
	if portsPlatform == "darwin" {
		if status := portsDaemon(tool, true, "kickstart", "-k", portsDaemonServiceTarget()); status == 0 {
			fmt.Fprintln(out, "Workspace ports: watcher started by the service manager")
			return 0
		}
	}
	args := portsDaemonStartArgs()
	if status := portsDaemon(tool, false, args...); status != 0 {
		fmt.Fprintf(errOut, "✖ port watcher not started: %s %v failed (status %d)\n", tool, args, status)
		return 1
	}
	fmt.Fprintln(out, "Workspace ports: watcher started by the service manager")
	return 0
}

// launchWatcher starts "<this binary> workspace ports loop" detached and
// returns its pid: no input, its output and errors appended to journal.log of
// the state folder (so the user can read what the watcher did), in a new
// session so that closing the terminal does not reach it. The parent closes
// its copy of the journal at once: the watcher keeps its own.
func launchWatcher(dir string) (int, error) {
	exe, err := watcherExecutable()
	if err != nil {
		return 0, err
	}
	journal, err := os.OpenFile(filepath.Join(dir, "journal.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, err
	}
	defer journal.Close()
	cmd := exec.Command(exe, "workspace", "ports", "loop")
	cmd.Stdout, cmd.Stderr = journal, journal
	return startDetached(cmd)
}
