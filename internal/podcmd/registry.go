package podcmd

import (
	"io"
	"sort"
)

// Handler func for a command
type Handler func(args []string, out, errOut io.Writer) int

// ported lists the commands of the pod ported to Go, by name.
var ported = map[string]Handler{
	"--version": printVersion,
	"-v":        printVersion,
}

// Ported returns the names of the commands that are ported to Go, sorted
func Ported() []string {
	cmds := make([]string, 0, len(ported))
	for cmd := range ported {
		cmds = append(cmds, cmd)
	}
	sort.Strings(cmds)
	return cmds
}
