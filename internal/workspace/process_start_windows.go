//go:build windows

package workspace

import (
	"os/exec"
	"syscall"
)

// Windows process rights and states missing from the standard syscall package.
// They are the fixed values of the Windows API, used to ask whether a relay is
// still running and to stop it (kill and kill -0 of the Unix watcher).
const (
	processQueryLimitedInformation = 0x1000
	stillActive                    = 259
	detachedProcess                = 0x00000008
	createNoWindow                 = 0x08000000
)

// startDetached starts cmd as a process that lives by itself and returns its
// pid (the "&" of pw_relay and of ports_start). The process gets no console and
// its own process group, so closing the terminal does not reach it. A goroutine
// waits for it: without one, a dead relay would stay a zombie that an
// OpenProcess/GetExitCodeProcess check still reports as alive.
func startDetached(cmd *exec.Cmd) (int, error) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= detachedProcess | syscall.CREATE_NEW_PROCESS_GROUP | createNoWindow
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	go func() { _ = cmd.Wait() }()
	return cmd.Process.Pid, nil
}
