//go:build !linux

package subreaper

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
)

// Supported is false outside Linux: no child subreaper flag exists there, so
// the session launcher does not wrap sessions at all and nothing changes.
const Supported = false

// Run runs argv as a plain child with the inherited standard streams and returns
// its code. It does not reap orphans: the platforms where it runs have no child
// subreaper, so this only keeps the subcommand usable for a manual check.
func Run(argv []string) Result {
	var res Result
	if len(argv) == 0 {
		fmt.Fprintln(os.Stderr, "devzone subreaper: no command given")
		res.Code = 2
		return res
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := cmd.Run()
	res.Code = exitCodeOf(err)
	return res
}

// exitCodeOf returns the exit code of a finished command. A command that could not
// start gives 127, as a shell does for a missing program.
func exitCodeOf(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return 127
}
