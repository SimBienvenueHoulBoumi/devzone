package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
)

// PortsAgentRun is the foreground command used by the launch agent or the user
// unit. It runs the watcher only when no live watcher already holds the state
// folder: a manual watcher at the moment of enable is never doubled. On
// Windows the automatic start does not exist (#883).
func PortsAgentRun(out, errOut io.Writer) int {
	if portsAutoStartGuard(errOut) {
		return 0
	}
	if portsPlatform == "windows" {
		fmt.Fprintln(errOut, "✖ devzone workspace ports agent: not available on windows (#883)")
		return 1
	}
	dir := portsDir()
	if pid := readPid(filepath.Join(dir, "pid")); alive(pid) {
		fmt.Fprintf(out, "Port watcher already running (pid %d)\n", pid)
		return 0
	}
	lock := filepath.Join(dir, "lock")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(errOut, "✖ port watcher: cannot create %s: %v\n", dir, err)
		return 1
	}
	_ = os.RemoveAll(lock)
	if err := os.Mkdir(lock, 0o755); err != nil {
		return 0
	}
	trimJournal(dir)
	journal, err := os.OpenFile(filepath.Join(dir, "journal.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		_ = os.RemoveAll(lock)
		fmt.Fprintf(errOut, "✖ port watcher: cannot open the journal: %v\n", err)
		return 1
	}
	defer journal.Close()
	if err := os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644); err != nil {
		_ = os.RemoveAll(lock)
		fmt.Fprintf(errOut, "✖ port watcher: cannot write the pid: %v\n", err)
		return 1
	}
	defer func() {
		_ = os.RemoveAll(lock)
		_ = os.Remove(filepath.Join(dir, "pid"))
	}()
	return portsLoopRunner(journal, journal, PortsStep())
}
