package command

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// zombiesProc is the proc folder the zombie report reads. Only the process
// namespace of the pod holds the orphans of the workspace, so the command runs there.
const zombiesProc = "/proc"

// zombiesCommand is `devzone workspace zombies` (#973): the zombie report of the
// workspace pod. It needs the pod's /proc, so it refuses on a workstation, where
// there is no such pod to read: the test is the variable the pod sets (DEVZONE_WORKSPACE).
func zombiesCommand(ctx *cli.Context) int {
	if os.Getenv("DEVZONE_WORKSPACE") != "kubernetes" {
		fmt.Fprintln(ctx.Err, "✖ devzone workspace zombies runs inside the workspace pod only: this workstation has no pod to read.")
		return 1
	}
	return workspace.Zombies(zombiesProc, ctx.Out, ctx.Err)
}
