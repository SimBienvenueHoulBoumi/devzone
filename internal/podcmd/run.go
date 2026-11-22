package podcmd

import (
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
)

// Run runs a pod command: handles <command> tells whether it is ported, a ported command runs in Go, any other command is delegated to the shell.
func Run(args []string, out, errOut io.Writer) int {
	if len(args) == 0 {
		return delegate(args, out, errOut)
	}

	switch args[0] {
	case "handles":
		if len(args) != 2 {
			io.WriteString(errOut, "usage: devzone-pod handles <command>\n")
			return 2
		}
		if _, ok := ported[args[1]]; ok {
			return 0
		}
		return 1
	default:
		if handler, ok := ported[args[0]]; ok {
			return handler(args[1:], out, errOut)
		}
		return delegate(args, out, errOut)
	}
}

// delegate runs the pod shell entry point with the same arguments; 127 when it is not found.
func delegate(args []string, out, errOut io.Writer) int {
	script, err := podScript()
	if err != nil {
		io.WriteString(errOut, err.Error()+"\n")
		return 127
	}

	return bashbridge.Run(script, args, os.Stdin, out, errOut)
}
