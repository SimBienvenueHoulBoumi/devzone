// Package command dispatches the devzone command line: a command ported to Go
// runs in-process, any other command is delegated to the bash entry point
// through internal/bashbridge (#358).
package command

import (
	"fmt"
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
)

// Run executes the command line args (without the program name) and returns
// the exit status. Standard input is passed on to the delegated bash command.
func Run(args []string, out, errOut io.Writer) int {
	if len(args) > 0 {
		if handler, ok := ported[args[0]]; ok {
			return handler(args[1:], out, errOut)
		}
	}
	return delegate(args, out, errOut)
}

// delegate hands the command line to the bash entry point, unchanged: a command
// not yet ported keeps its behaviour.
func delegate(args []string, out, errOut io.Writer) int {
	script, err := bashbridge.Script(os.Getenv(bashbridge.EnvVar))
	if err != nil {
		fmt.Fprintf(errOut, "devzone: %v\n", err)
		return 1
	}
	return bashbridge.Run(script, args, os.Stdin, out, errOut)
}
