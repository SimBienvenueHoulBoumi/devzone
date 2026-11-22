//go:build !windows

package workspace

import (
	"os/exec"
	"syscall"
)

// startDetached starts cmd as a process that lives by itself and returns its pid
// (the "&" of pw_relay and of ports_start): no input, output or error unless the
// caller set one on cmd (the watcher gets the journal; a relay gets none, the
// default being the null device), and a new session so that Ctrl-C in the
// terminal of the parent does not reach it.
// A goroutine waits for the process: a shell collects its dead children on its
// own, Go does not, and a child that is not collected stays a zombie, which
// kill -0 (alive) still reports as alive. Without it a relay that died would
// never be started again by the next round.
func startDetached(cmd *exec.Cmd) (int, error) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	go func() { _ = cmd.Wait() }()
	return cmd.Process.Pid, nil
}
