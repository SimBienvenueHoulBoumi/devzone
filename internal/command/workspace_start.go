package command

import (
	"fmt"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// commandKubeReady and commandArgoCDInstalled are injectable so a test can
// exercise the routing of start without a cluster, a fake kubectl or a shell.
var (
	commandKubeReady       = workspace.KubeReady
	commandArgoCDInstalled = workspace.ArgoCDInstalled
)

// startWorkspace checks the cluster before anything else, as start_workspace
// does: an unreachable cluster must not even ask whether Argo CD is installed.
// It then runs the helm-direct form in Go when Argo CD is off and absent from
// the cluster; the forms that need Argo CD or its GitOps repository stay
// delegated to the shell. It does not install the automatic start itself: the
// single function of #906 is called by Run after a successful command. When the
// Go program is absent, the shell entry point still does the cluster work.
func startWorkspace(ctx *cli.Context) int {
	reason, ready := commandKubeReady(workspace.ExecRunner{}, true)
	if !ready {
		fmt.Fprintln(ctx.Err, reason)
		return 1
	}
	args := append([]string{"workspace"}, ctx.Args...)
	if !workspace.ArgoCDWanted(modulesFile()) && !commandArgoCDInstalled(workspace.ExecRunner{}) {
		env := workspace.StartEnv{
			Runner: workspace.ExecRunner{}, Modules: modulesFile(),
			Out: ctx.Out, ErrOut: ctx.Err,
			Ready: func() (string, bool) { return "", true },
		}
		return env.Run(ctx.Args[1:])
	}
	return delegate(args, ctx.Out, ctx.Err)
}
