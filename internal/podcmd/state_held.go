package podcmd

import (
	"fmt"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// runStateHeld prints, for "devzone status", the line that says a service is
// driven by an Argo CD Application. Nothing is printed for any other module, so
// the status line of a module without Argo CD stays unchanged.
func runStateHeld(ctx *cli.Context, st *state.State) int {
	if len(ctx.Args) != 2 {
		fmt.Fprintln(ctx.Err, "devzone state held: module")
		return 2
	}
	name := ctx.Args[1]
	if heldByArgoCD(jsonDeps{ctx: ctx, st: st}, name) {
		fmt.Fprintf(ctx.Out, "tenu par Argo CD : Application devzone-%s\n", name)
	}
	return 0
}
