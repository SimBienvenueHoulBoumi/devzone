//go:build windows

package workspace

import "syscall"

// terminate asks process pid to stop, as kill does in the Unix watcher. It
// opens the process with the terminate right and asks it to exit; a process
// that is gone or that cannot be opened is already stopped, so there is nothing
// to report. The handle is always closed, including on failure.
func terminate(pid int) {
	if pid < 1 {
		return
	}
	handle, err := syscall.OpenProcess(syscall.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return
	}
	defer syscall.CloseHandle(handle)
	_ = syscall.TerminateProcess(handle, 1)
}

// alive reports whether process pid exists and is still running (kill -0 in
// the Unix watcher). A number below 1 is never a watcher process: 0 and
// negative numbers would address other things, so they are refused. An open
// handle alone is not enough: a process that has exited but whose handle is
// still open reports STILL_ACTIVE, so its exit code decides.
func alive(pid int) bool {
	if pid < 1 {
		return false
	}
	handle, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(handle)
	var code uint32
	if err := syscall.GetExitCodeProcess(handle, &code); err != nil {
		return false
	}
	return code == stillActive
}
