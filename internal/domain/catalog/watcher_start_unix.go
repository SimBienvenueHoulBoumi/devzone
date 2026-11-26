//go:build !windows

package catalog

import (
	"os/exec"
	"syscall"
)

// startDetachedWatcher starts cmd in a new session, so that closing the
// terminal of the caller does not stop the watcher. A goroutine reaps the
// child: a zombie would still answer kill -0 and forbid the next start.
func startDetachedWatcher(cmd *exec.Cmd) (int, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	go func() { _ = cmd.Wait() }()
	return cmd.Process.Pid, nil
}
