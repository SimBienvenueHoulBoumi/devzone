// Package bashbridge runs the bash entry point of devzone (manage/devzone) as a
// child process. It is the fallback of the strangler migration (#358): each
// command not yet ported to Go goes through here, unchanged. It imports no
// package of this repository.
package bashbridge

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
)

// FromGoVar is set to 1 in the environment of the bash child. The bash entry
// point (manage/devzone) launches the Go binary of the package when there is
// one; this variable tells it that the call comes from that binary, so that it
// does not launch it again (an endless loop otherwise).
const FromGoVar = "DEVZONE_FROM_GO"

// Run executes "bash script args..." and returns the exit status of the script.
// Standard input, output and error and working directory are inherited, and so
// is the environment, plus FromGoVar: the script behaves as if it had been typed
// in the shell. A child killed by a signal gives 128 + the signal number, as a
// shell does.
func Run(script string, args []string, in io.Reader, out, errOut io.Writer) int {
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), FromGoVar+"=1")
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
