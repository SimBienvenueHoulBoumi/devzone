// Package bashbridge runs the bash entry point of devzone (manage/devzone) as a
// child process. It is the fallback of the strangler migration (#358): each
// command not yet ported to Go goes through here, unchanged. It imports no
// package of this repository.
package bashbridge

import (
	"errors"
	"fmt"
	"io"
	"os/exec"
	"syscall"
)

// Run executes "bash script args..." and returns the exit status of the script.
// Standard input, output and error, working directory and environment are
// inherited: the script behaves as if it had been typed in the shell. A child
// killed by a signal gives 128 + the signal number, as a shell does.
func Run(script string, args []string, in io.Reader, out, errOut io.Writer) int {
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Stdin = in
	cmd.Stdout = out
	cmd.Stderr = errOut
	err := cmd.Run()
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return statusOf(exitErr)
	}
	// Not an exit status: bash could not be started (not in PATH, for example)
	fmt.Fprintf(errOut, "devzone: cannot start bash: %v\n", err)
	return 127
}

// statusOf returns the shell status of a child that has exited: its exit code,
// or 128 + the number of the signal that killed it.
func statusOf(exitErr *exec.ExitError) int {
	if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return exitErr.ExitCode()
}
