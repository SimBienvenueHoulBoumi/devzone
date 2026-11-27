package podcmd

import (
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/subreaper"
)

// runSubreaper handles `devzone-pod subreaper -- <command> [args...]` (#973): the
// command runs as the child of a process that reaps its orphans, so that they do
// not stay zombies under a PID 1 that never calls wait. The session launcher of
// `agent` calls it; it is not listed in the help. The result is the exit status
// of the command.
func runSubreaper(ctx *cli.Context) int {
	argv := ctx.Args[1:]
	if len(argv) > 0 && argv[0] == "--" {
		argv = argv[1:]
	}
	return subreaper.Run(argv).Code
}

// reaperExecutable returns the path of this binary when the platform can act as
// a child subreaper, and "" otherwise, so that the sessions start as they did.
// Why: the wrapper exists only where prctl does; elsewhere it must not change anything.
func reaperExecutable() string {
	if !subreaper.Supported {
		return ""
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return exe
}
