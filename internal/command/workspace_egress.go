package command

import (
	"fmt"
	"os/exec"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// The collaborators of "workspace egress" are variables so that a test drives
// the command with a fake Runner, a fake program lookup and a fake deploy.
var (
	egressRunner   workspace.Runner = workspace.ExecRunner{}
	egressLookPath                  = exec.LookPath
	egressSleep                     = time.Sleep
	egressDeploy                    = deployWorkspaceAt
)

// egressCommand runs "workspace egress" in Go (#934). The internal "params"
// word prints the chart parameters that start and update replay, as
// egress_params did; the other words change or show the proxy settings.
func egressCommand(ctx *cli.Context) int {
	args := ctx.Args[1:]
	if len(args) == 1 && args[0] == "params" {
		fmt.Fprint(ctx.Out, workspace.EgressParams(modulesFile()))
		return 0
	}
	env := workspace.EgressEnv{
		Runner:   egressRunner,
		Modules:  modulesFile(),
		Out:      ctx.Out,
		ErrOut:   ctx.Err,
		LookPath: egressLookPath,
		Sleep:    egressSleep,
		Deploy: func(repository, tag, revision string) int {
			return egressDeploy(ctx, repository, tag, revision)
		},
	}
	return env.Run(args)
}
