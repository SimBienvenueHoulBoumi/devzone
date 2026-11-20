package command

import (
	"io"
	"sort"
)

// Handler runs a command ported to Go: it writes to out and errOut and returns
// the exit status.
type Handler func(args []string, out, errOut io.Writer) int

// ported lists the commands implemented in Go, by name. It is empty until the
// first command is ported (#358): until then every command is delegated to bash.
var ported = map[string]Handler{}

// Ported returns the names of the commands implemented in Go, sorted.
func Ported() []string {
	names := make([]string, 0, len(ported))
	for name := range ported {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
