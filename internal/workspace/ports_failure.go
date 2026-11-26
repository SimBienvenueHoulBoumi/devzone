package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// portsFailureName is the marker of an automatic start that the service manager
// refused in this devzone folder. It is not a user refusal (see ports_refusal):
// it records that enable failed with this program, so no automatic attempt
// repeats until the program changes or ports enable runs explicitly.
const portsFailureName = ".devzone.ports-autostart-failed"

// portsWatcherLauncher starts the watcher by hand in a state folder and returns
// its pid. It is a variable so that a test can start a sleep process instead.
var portsWatcherLauncher = launchWatcher

// portsFailureFile returns the failure marker of the current devzone folder.
func portsFailureFile() string {
	return filepath.Join(portsDevzoneFolder(), portsFailureName)
}

// portsProgramFingerprint identifies the running devzone program by its
// contents, so a new build retries the automatic start. It is empty when the
// program cannot be read.
func portsProgramFingerprint() string {
	exe, err := watcherExecutable()
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(exe)
	if err != nil {
		return ""
	}
	return portsNameFingerprint(string(data))
}

// PortsAutoStartFailed reports whether the automatic start failed with the
// running devzone program, so that no automatic attempt is made again.
func PortsAutoStartFailed() bool {
	data, err := os.ReadFile(portsFailureFile())
	if err != nil {
		return false
	}
	fingerprint := portsProgramFingerprint()
	return fingerprint != "" && strings.TrimSpace(string(data)) == fingerprint
}

// rememberPortsAutoStartFailure writes the failure marker, only inside an
// existing devzone folder.
func rememberPortsAutoStartFailure() {
	if info, err := os.Stat(portsDevzoneFolder()); err != nil || !info.IsDir() {
		return
	}
	_ = os.WriteFile(portsFailureFile(), []byte(portsProgramFingerprint()+"\n"), 0o644)
}

// forgetPortsAutoStartFailure removes the failure marker; an absent marker is
// not an error.
func forgetPortsAutoStartFailure() {
	_ = os.Remove(portsFailureFile())
}

// portsWatcherRunning tells whether a watcher started by hand is alive.
func portsWatcherRunning() bool {
	return alive(readPid(filepath.Join(portsDir(), "pid")))
}

// startManualWatcher starts the watcher by hand in dir, with the lock and the
// pid as PortsStart writes them.
func startManualWatcher(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	lock := filepath.Join(dir, "lock")
	_ = os.RemoveAll(lock)
	if err := os.Mkdir(lock, 0o755); err != nil {
		return err
	}
	pid, err := portsWatcherLauncher(dir)
	if err != nil {
		_ = os.RemoveAll(lock)
		return err
	}
	return os.WriteFile(filepath.Join(dir, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644)
}

// portsEnableFailed undoes a refused enable: the definition is unloaded and
// removed, the manual watcher that ran before is started again, the failure is
// remembered, and one warning line is printed. It returns the status of enable.
func portsEnableFailed(errOut io.Writer, tool string, args []string, status int, wasRunning bool) int {
	_ = portsDaemon(tool, true, portsDaemonDisableArgs()...)
	_ = portsAgentRemove(portsAgentDir(), portsAgentName())
	portsDaemonReload(tool)
	manual := "no manual watcher was running"
	if wasRunning {
		manual = "the manual watcher runs again"
		if err := startManualWatcher(portsDir()); err != nil {
			manual = "the manual watcher did not start again: " + strings.ReplaceAll(err.Error(), "\n", " ")
		}
	}
	rememberPortsAutoStartFailure()
	fmt.Fprintf(errOut, "⚠ port watcher automatic start not enabled: %s %v failed (status %d); the definition is removed, %s; automatic attempts stop until devzone changes or devzone workspace ports enable runs\n",
		tool, args, status, manual)
	return 1
}
