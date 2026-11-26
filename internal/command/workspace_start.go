package command

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// startWorkspace runs the helm-direct form of "devzone workspace start" in Go
// when Argo CD is off and absent from the cluster; the forms that need Argo CD
// or its GitOps repository stay delegated to the shell. It does not install the
// automatic start itself: the single function of #906 is called by Run after a
// successful command, so start, creation and update share one silent,
// idempotent path. A failed start therefore installs nothing. When the Go
// program is absent, the shell entry point still does the cluster work.
func startWorkspace(ctx *cli.Context) int {
	args := append([]string{"workspace"}, ctx.Args...)
	if !workspace.ArgoCDWanted(modulesFile()) && !workspace.ArgoCDInstalled(workspace.ExecRunner{}) {
		env := workspace.StartEnv{
			Runner: workspace.ExecRunner{}, Modules: modulesFile(),
			Out: ctx.Out, ErrOut: ctx.Err,
		}
		return env.Run(ctx.Args)
	}
	return delegate(args, ctx.Out, ctx.Err)
}
