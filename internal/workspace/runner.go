// Package workspace holds the subcommands of "devzone workspace" ported to Go
// (#712). Each one drives kubectl and helm through a Runner, so that tests run
// without a cluster. Options, outputs and exit statuses follow manage/workspace.sh.
package workspace

import (
	"errors"
	"io"
	"os/exec"
	"syscall"
)

// Runner runs kubectl and helm with args. When stdin is not nil it is piped to
// the command; the standard output and error of the command go to stdout and
// stderr. Each method returns the exit status of the command, or an error when
// the command cannot be started.
type Runner interface {
	Kubectl(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error)
	Helm(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error)
}

// ExecRunner runs the kubectl and helm found in PATH, as the bash entry point does.
type ExecRunner struct{}

// Kubectl runs kubectl with args (see Runner).
func (ExecRunner) Kubectl(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return execCommand("kubectl", args, stdin, stdout, stderr)
}

// Helm runs helm with args (see Runner).
func (ExecRunner) Helm(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return execCommand("helm", args, stdin, stdout, stderr)
}

// execCommand runs the program name found in PATH (see Runner). A child killed by
// a signal gives 128 + the signal number, as a shell does.
func execCommand(name string, args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	cmd := exec.Command(name, args...)
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return statusOf(exitErr), nil
	}
	return 0, err
}

// statusOf returns the shell status of a child that has exited: its exit code,
// or 128 plus the number of the signal that killed it.
func statusOf(exitErr *exec.ExitError) int {
	if ws, ok := exitErr.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return exitErr.ExitCode()
}
