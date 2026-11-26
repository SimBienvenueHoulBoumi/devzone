//go:build windows

package catalog

import (
	"syscall"
	"unsafe"
)

// Win32 calls used to test and stop a watcher process on Windows; no external
// dependency is needed for the equivalent of kill -0 and kill TERM.
var (
	watcherKernel32    = syscall.NewLazyDLL("kernel32.dll")
	watcherOpenProcess = watcherKernel32.NewProc("OpenProcess")
	watcherExitCode    = watcherKernel32.NewProc("GetExitCodeProcess")
	watcherCloseHandle = watcherKernel32.NewProc("CloseHandle")
	watcherTerminate   = watcherKernel32.NewProc("TerminateProcess")
)

const (
	watcherQueryLimit      = 0x1000
	watcherTerminateAccess = 0x0001
	watcherStillActive     = 259
)

// openWatcherProcess opens pid with the requested access, or returns an error.
func openWatcherProcess(pid, access int) (syscall.Handle, error) {
	handle, _, err := watcherOpenProcess.Call(uintptr(access), 0, uintptr(pid))
	if handle == 0 {
		return 0, err
	}
	return syscall.Handle(handle), nil
}

// processAlive reports whether pid names a process that has not exited.
func processAlive(pid int) bool {
	handle, err := openWatcherProcess(pid, watcherQueryLimit)
	if err != nil {
		return false
	}
	defer watcherCloseHandle.Call(uintptr(handle))
	var code uint32
	result, _, _ := watcherExitCode.Call(uintptr(handle), uintptr(unsafe.Pointer(&code)))
	return result != 0 && code == watcherStillActive
}

// processKill terminates the watcher process, ignoring an already gone one.
func processKill(pid int) error {
	handle, err := openWatcherProcess(pid, watcherTerminateAccess)
	if err != nil {
		return err
	}
	defer watcherCloseHandle.Call(uintptr(handle))
	result, _, err := watcherTerminate.Call(uintptr(handle), 1)
	if result == 0 {
		return err
	}
	return nil
}
