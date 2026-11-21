package command

import (
	"io"
	"sort"
)

// Handler runs a command ported to Go: it writes to out and errOut and returns
// the exit status.
type Handler func(args []string, out, errOut io.Writer) int

// ported lists the commands implemented in Go, by name (#358). A name runs in Go
// only when it stands alone: with an argument, see bare. The workspace name runs
// in Go for its status subcommand alone (#712), see workspaceCommand.
var ported = map[string]Handler{
	"--version": bare("--version", printVersion),
	"-v":        bare("-v", printVersion),
	"help":      bare("help", printHelp),
	"-h":        bare("-h", printHelp),
	"--help":    bare("--help", printHelp),
	"workspace": workspaceCommand,
}

// bare builds the handler of a command that takes no argument. With an argument,
// the whole command line goes to bash: bash checks the renamed names first
// (reject_renamed) and stays the reference for the extra words.
func bare(name string, run func(out io.Writer) int) Handler {
	return func(args []string, out, errOut io.Writer) int {
		if len(args) > 0 {
			return delegate(append([]string{name}, args...), out, errOut)
		}
		return run(out)
	}
}

// Ported returns the names of the commands implemented in Go, sorted.
func Ported() []string {
	names := make([]string, 0, len(ported))
	for name := range ported {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
