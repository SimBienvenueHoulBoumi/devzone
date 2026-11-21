//go:build !windows

package workspace

import "syscall"

// terminate asks process pid to stop with SIGTERM (kill in the shell).
func terminate(pid int) {
	_ = syscall.Kill(pid, syscall.SIGTERM)
}

// alive reports whether process pid exists and can be signalled (pw_alive, kill -0).
// A number below 1 is never a process of the watcher: 0 and negative numbers would
// address groups of processes, so they are refused.
func alive(pid int) bool {
	return pid >= 1 && syscall.Kill(pid, 0) == nil
}
