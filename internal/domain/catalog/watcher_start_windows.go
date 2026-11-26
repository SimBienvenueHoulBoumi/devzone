//go:build windows

package catalog

import (
	"os/exec"
	"syscall"
)

// Windows creation flags: a detached process in its own group survives the
// caller and can be stopped as a whole, as setsid does on Unix.
const watcherDetachedFlags = 0x00000008 | 0x00000200

// startDetachedWatcher starts cmd detached on Windows and reaps it, so that a
// dead watcher never leaves a lock held by a phantom process.
func startDetachedWatcher(cmd *exec.Cmd) (int, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: watcherDetachedFlags}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	go func() { _ = cmd.Wait() }()
	return cmd.Process.Pid, nil
}
