package command

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// startWorkspace delegates the cluster work of "devzone workspace start" to the
// shell entry point. The automatic start is no longer installed here: the
// single function of #906 is called by Run for every user command of a devzone
// folder, so start, creation and update all share one silent, idempotent path.
// When the Go program is absent, only the cluster work runs.
func startWorkspace(ctx *cli.Context) int {
	return delegate(append([]string{"workspace"}, ctx.Args...), ctx.Out, ctx.Err)
}
