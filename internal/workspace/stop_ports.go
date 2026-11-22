package workspace

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// portsStateName is the state folder of the port watcher, in the folder of the
// workstation shell (pw_dir in manage/scripts/workspace/ports-workspace.sh).
const portsStateName = ".devzone.workspace-ports"

// The watcher is waited for during stopPoll steps, stopPolls at most (ports_stop).
const (
	stopPoll  = 200 * time.Millisecond
	stopPolls = 10
)

// stopPorts stops the port watcher and its relays, as ports_stop does: the watcher
// gets SIGTERM and is waited for, every relay is stopped, then the lock and the pid
// file are removed. Nothing is printed, and a missing state folder is not an error.
func stopPorts() {
	dir := portsDir()
	pid := readPid(filepath.Join(dir, "pid"))
	if alive(pid) {
		terminate(pid)
		for i := 0; i < stopPolls && alive(pid); i++ {
			time.Sleep(stopPoll)
		}
	}
	removeRelays(dir)
	_ = os.RemoveAll(filepath.Join(dir, "lock"))
	_ = os.RemoveAll(filepath.Join(dir, "pid"))
}

// portsDir returns the state folder of the port watcher: DEVZONE_PORTS_WORKSPACE_DIR
// when it is set and not empty, else the folder of the shell (PWD) (pw_dir).
func portsDir() string {
	if dir := os.Getenv("DEVZONE_PORTS_WORKSPACE_DIR"); dir != "" {
		return dir
	}
	wd := os.Getenv("PWD")
	if wd == "" {
		wd, _ = os.Getwd()
	}
	return filepath.Join(wd, portsStateName)
}

// removeRelays stops every relay of the state folder and removes its files
// (pw_remove_all). Hidden and missing entries are skipped, as the shell glob does.
func removeRelays(dir string) {
	entries, err := os.ReadDir(filepath.Join(dir, "relays"))
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, "relays", name)); err != nil {
			continue
		}
		removeRelay(dir, name)
	}
}

// removeRelay stops the relay process of port name, if alive, and removes its
// files in relays and taken (pw_remove).
func removeRelay(dir, name string) {
	if pid := readPid(filepath.Join(dir, "relays", name)); alive(pid) {
		terminate(pid)
	}
	_ = os.Remove(filepath.Join(dir, "relays", name))
	_ = os.Remove(filepath.Join(dir, "taken", name))
}

// readPid returns the process number written in file, or 0 when the file is
// missing or holds no number (cat ... || true in the shell).
func readPid(file string) int {
	data, err := os.ReadFile(file)
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0
	}
	return pid
}
