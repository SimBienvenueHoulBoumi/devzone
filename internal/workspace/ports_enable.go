package workspace

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// PortsEnable installs the automatic start of the port watcher of this devzone
// folder: a watcher started by hand is stopped and waited for, the binary is
// copied into a stable folder of the user, the definition of the launch agent or
// user unit is written, then the service manager starts the watcher. Installing
// twice replaces the copy and the definition without ever leaving two watchers:
// it is the manager, not enable, that owns the process afterwards. On Linux a
// replaced copy is followed by an explicit restart, because enable --now leaves
// an already active unit running the old binary. The watcher itself runs in Go
// on Windows too, but its automatic start is another ticket and is refused here.
func PortsEnable(out, errOut io.Writer) int {
	if portsAutoStartGuard(errOut) {
		return 0
	}
	if portsPlatform == "windows" {
		fmt.Fprintln(errOut, "✖ devzone workspace ports enable: automatic start is not available on windows (#883)")
		return 1
	}
	env, err := portsAgentEnvironment()
	if err != nil {
		fmt.Fprintf(errOut, "✖ port watcher: %v\n", err)
		return 1
	}
	forgetPortsAutoStartFailure()
	wasRunning := portsWatcherRunning()
	stopPorts()
	exe, err := watcherExecutable()
	if err != nil {
		fmt.Fprintf(errOut, "✖ port watcher: cannot find the binary: %v\n", err)
		return 1
	}
	copyPath := portsWatcherCopyPath()
	replaced, err := copyWatcher(exe, copyPath)
	if err != nil {
		fmt.Fprintf(errOut, "✖ port watcher: cannot copy %s to %s: %v\n", exe, copyPath, err)
		return 1
	}
	definition, err := portsAgentWrite(portsAgentDir(), portsAgentName(), copyPath, portsDevzoneFolder(), env)
	if err != nil {
		fmt.Fprintf(errOut, "✖ port watcher: cannot write the automatic start file: %v\n", err)
		return 1
	}
	if portsPlatform == "darwin" {
		// A loaded agent would make the bootstrap fail; unloading an absent one
		// fails too and is ignored, which keeps enable repeatable.
		_ = portsDaemon(portsDaemonTool(), true, "bootout", portsDaemonServiceTarget())
	}
	tool := portsDaemonTool()
	args := portsDaemonEnableArgs(definition)
	if status := portsDaemon(tool, false, args...); status != 0 {
		return portsEnableFailed(errOut, tool, args, status, wasRunning)
	}
	if replaced && portsPlatform != "darwin" {
		restart := portsDaemonRestartArgs()
		if status := portsDaemon(tool, false, restart...); status != 0 {
			return portsEnableFailed(errOut, tool, restart, status, wasRunning)
		}
	}
	fmt.Fprintln(out, "✔ port watcher: automatic start enabled")
	return 0
}

// PortsDisable removes the automatic start of this devzone folder: the service
// manager first disables or unloads the definition while it still exists, then
// the file is deleted and systemd reloads again. The running watcher is stopped
// without being relaunched until the next start, enable or session. Repeating
// disable is not an error and says nothing when there is nothing to remove.
func PortsDisable(out, errOut io.Writer) int {
	if portsAutoStartGuard(errOut) {
		return 0
	}
	if portsPlatform == "windows" {
		return 0
	}
	existed := portsAgentExists()
	tool := portsDaemonTool()
	if existed {
		args := portsDaemonDisableArgs()
		status := portsDaemon(tool, portsPlatform == "darwin", args...)
		if status != 0 && portsPlatform != "darwin" {
			fmt.Fprintf(errOut, "✖ port watcher automatic start not disabled: %s %v failed (status %d)\n", tool, args, status)
			return status
		}
		portsDaemonReload(tool)
		if err := portsAgentRemove(portsAgentDir(), portsAgentName()); err != nil {
			fmt.Fprintf(errOut, "✖ port watcher automatic start not removed: %v\n", err)
			return 1
		}
		portsDaemonReload(tool)
	}
	stopPorts()
	if existed {
		fmt.Fprintln(out, "✔ port watcher: automatic start disabled")
	}
	return 0
}

// portsDaemonReload asks systemd to reread its units, before and after the
// definition is removed so neither the old nor the new state stays cached.
// macOS has no daemon-reload equivalent: launchctl reads the agent file at boot.
func portsDaemonReload(tool string) {
	if portsPlatform == "darwin" {
		return
	}
	_ = portsDaemon(tool, false, "--user", "daemon-reload")
}

// portsAutoStartGuard refuses to load a service manager during bats unless the
// test explicitly opts in, as PortsStart refuses to launch a real watcher. It
// reports whether the command must stop before touching any file or daemon.
func portsAutoStartGuard(errOut io.Writer) bool {
	if os.Getenv("BATS_TEST_TMPDIR") == "" || os.Getenv("DEVZONE_PORTS_WORKSPACE_REAL") == "yes" {
		return false
	}
	fmt.Fprintln(errOut, "✖ port watcher automatic start refused under bats (DEVZONE_PORTS_WORKSPACE_REAL=yes required)")
	return true
}

// portsDevzoneFolder returns the working folder written in the definition:
// DEVZONE_ROOT, then PWD, then the current folder.
func portsDevzoneFolder() string {
	if root := os.Getenv("DEVZONE_ROOT"); root != "" {
		return root
	}
	if wd := os.Getenv("PWD"); wd != "" {
		return wd
	}
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return "."
}

// copyWatcher installs the contents of exe at path, executable and readable.
// It writes a temporary file of the same folder and renames it over path, so a
// process still running from the old file does not block the replacement and
// never sees a partially written program. It reports whether an existing file
// was replaced, and does nothing when path already holds the same contents.
func copyWatcher(exe, path string) (bool, error) {
	source, err := filepath.Abs(exe)
	if err != nil {
		return false, err
	}
	target, err := filepath.Abs(path)
	if err != nil {
		return false, err
	}
	if source == target {
		return false, nil
	}
	data, err := os.ReadFile(exe)
	if err != nil {
		return false, err
	}
	_, statErr := os.Stat(path)
	existed := statErr == nil
	if current, err := os.ReadFile(path); err == nil && bytes.Equal(current, data) {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".devzone-watcher-*")
	if err != nil {
		return false, err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Chmod(0o755); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return false, err
	}
	return existed, nil
}
