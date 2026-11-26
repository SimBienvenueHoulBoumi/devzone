//go:build !windows

package catalog

import (
	"os"
	"syscall"
)

// processAlive reports whether pid names a live process, as kill -0 did.
func processAlive(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return process.Signal(syscall.Signal(0)) == nil
}

// processKill asks the watcher to stop, as the shell stop did.
func processKill(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(syscall.SIGTERM)
}
