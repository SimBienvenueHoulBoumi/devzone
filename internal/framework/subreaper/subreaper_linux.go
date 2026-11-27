//go:build linux

package subreaper

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

// Supported is true on Linux, where a process can declare itself a child
// subreaper with prctl(PR_SET_CHILD_SUBREAPER).
const Supported = true

// prSetChildSubreaper is PR_SET_CHILD_SUBREAPER from <linux/prctl.h>. The syscall
// package does not export it, and the module has no x/sys dependency.
const prSetChildSubreaper = 36

// forwarded are the signals passed on to the child. The wrapper keeps waiting
// after them: the child decides how to end, as it would without a wrapper.
var forwarded = []os.Signal{syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT}

// Run starts argv[0] with argv[1:] as the child of this process, after this
// process has become a child subreaper, and returns when that child has ended.
// Orphans of the subtree are collected with wait4(-1) while the child runs, so
// none stays a zombie. Standard streams are inherited. Why it waits for the
// direct child only: a background process that outlives the session must not
// keep the session open; the orphans still running are left to their own end.
func Run(argv []string) Result {
	var res Result
	if len(argv) == 0 {
		fmt.Fprintln(os.Stderr, "devzone subreaper: no command given")
		res.Code = 2
		return res
	}
	path, err := exec.LookPath(argv[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "devzone subreaper: %s: not found\n", argv[0])
		res.Code = 127
		return res
	}
	res.Subreaper = becomeSubreaper() == nil
	sigs := make(chan os.Signal, len(forwarded))
	signal.Notify(sigs, forwarded...)
	defer signal.Stop(sigs)
	child, err := os.StartProcess(path, argv, &os.ProcAttr{
		Env:   os.Environ(),
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "devzone subreaper: %s: %v\n", argv[0], err)
		res.Code = 126
		return res
	}
	done := make(chan struct{})
	defer close(done)
	go forward(sigs, child.Pid, done)
	status, ok := reapUntil(child.Pid, &res)
	drainZombies(&res)
	if !ok {
		res.Code = 1
		return res
	}
	res.Code = exitCode(status)
	return res
}

// becomeSubreaper declares this process a child subreaper, so that orphans of
// its subtree are re-parented to it and not to PID 1. Returns the kernel error
// on a kernel older than 3.4 or a seccomp profile that refuses prctl.
func becomeSubreaper() error {
	_, _, errno := syscall.Syscall6(syscall.SYS_PRCTL, prSetChildSubreaper, 1, 0, 0, 0, 0)
	if errno != 0 {
		return errno
	}
	return nil
}

// reapUntil collects every exited child until the direct child pid is among
// them, and returns its wait status. Each other pid is an orphan of the subtree,
// recorded in res. ok is false when no child is left before pid exits.
func reapUntil(pid int, res *Result) (status syscall.WaitStatus, ok bool) {
	for {
		var ws syscall.WaitStatus
		got, err := syscall.Wait4(-1, &ws, 0, nil)
		switch {
		case err == syscall.EINTR:
			continue
		case err != nil:
			return 0, false
		case got == pid:
			return ws, true
		default:
			res.Reaped = append(res.Reaped, got)
		}
	}
}

// drainZombies collects the orphans that already exited when the direct child
// ends, without waiting for the ones still running (WNOHANG). Their pids go to res.
func drainZombies(res *Result) {
	for {
		var ws syscall.WaitStatus
		got, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
		if err != nil || got <= 0 {
			return
		}
		res.Reaped = append(res.Reaped, got)
	}
}

// forward passes each signal received by the wrapper to the child pid, until done
// is closed. A signal sent to the process group reaches the child too; the
// double delivery is harmless for the signals a session handles.
func forward(sigs <-chan os.Signal, pid int, done <-chan struct{}) {
	for {
		select {
		case s := <-sigs:
			if sig, ok := s.(syscall.Signal); ok {
				_ = syscall.Kill(pid, sig)
			}
		case <-done:
			return
		}
	}
}

// exitCode turns a wait status into the code the wrapper returns: the exit code
// of the child, or 128 plus the signal number that killed it, as a shell does.
func exitCode(ws syscall.WaitStatus) int {
	switch {
	case ws.Exited():
		return ws.ExitStatus()
	case ws.Signaled():
		return 128 + int(ws.Signal())
	}
	return 1
}
