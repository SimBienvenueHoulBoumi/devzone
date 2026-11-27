// Package command dispatches the devzone command line: a command ported to Go
// runs in-process, any other command is delegated to the bash entry point
// through internal/bashbridge (#358).
package command

import (
	"fmt"
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Run executes the command line args (without the program name) and returns
// the exit status. Without argument, the help is shown, as manage/devzone does.
// Standard input is passed on to the delegated bash command.
func Run(args []string, out, errOut io.Writer) int {
	if refuseInPod(errOut) {
		return 1
	}
	if len(args) == 0 {
		args = []string{"help"}
	}
	ctx := &cli.Context{Out: out, Err: errOut, Runner: exec.ExecRunner{}}
	code, handled := Registry.Run(args, ctx)
	if !handled {
		code = delegate(args, out, errOut)
	}
	if code == 0 {
		maybeEnsurePortsAutoStart(args, out, errOut)
	}
	return code
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
