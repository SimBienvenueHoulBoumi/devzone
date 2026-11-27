package command

import (
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// The collaborators of a workspace update are variables so a test can drive the
// whole command without git, the registry, a cluster, a terminal or bash.
var (
	updateRunner      workspace.Runner = workspace.ExecRunner{}
	updateTags                         = workspace.GitTags
	updateImageExists                  = workspace.RegistryImageExists
	updateDeploy                       = deployWorkspaceAt
	updateReconcile                    = reconcileServices
	updateReady                        = func(r workspace.Runner) (string, bool) { return workspace.KubeReady(r, true) }
)

// updateWorkspace runs "workspace update" in Go: it parses the options, resolves
// the release, checks its image and confirms before deploying at that release,
// as update_workspace did in manage/scripts/workspace/workspace-update.sh.
func updateWorkspace(ctx *cli.Context) int {
	env := workspace.UpdateEnv{
		Runner: updateRunner, Modules: modulesFile(), Out: ctx.Out, ErrOut: ctx.Err,
		Tags: updateTags, ImageExists: updateImageExists,
		Ready: func() (string, bool) { return updateReady(updateRunner) },
		Deploy: func(repository, tag, revision string) int {
			return updateDeploy(ctx, repository, tag, revision)
		},
		Reconcile: func() int { return updateReconcile(ctx) },
	}
	return env.Run(ctx.Args[1:])
}

// deployWorkspaceAt deploys the workspace at one release: the Argo CD
// Application when it holds the charts, otherwise the helm release directly.
// The revision reaches the Argo CD resolver through DEVZONE_ARGOCD_REVISION, as
// the shell update exported it, and is restored afterwards so a test or a
// caller keeps its environment.
func deployWorkspaceAt(ctx *cli.Context, repository, tag, revision string) int {
	previous, had := os.LookupEnv("DEVZONE_ARGOCD_REVISION")
	_ = os.Setenv("DEVZONE_ARGOCD_REVISION", revision)
	defer func() {
		if had {
			_ = os.Setenv("DEVZONE_ARGOCD_REVISION", previous)
			return
		}
		_ = os.Unsetenv("DEVZONE_ARGOCD_REVISION")
	}()
	deployCtx := &cli.Context{Args: []string{"deploy", repository, tag, ""}, Out: ctx.Out, Err: ctx.Err, Runner: ctx.Runner}
	if code := workspaceDeploy(deployCtx); code != 3 {
		return code
	}
	return workspace.HelmDeploy(updateRunner, modulesFile(), repository, tag, false, ctx.Out, ctx.Err)
}

// reconcileServices applies or releases the service Applications after the
// workspace moved, as services_reconcile did when Argo CD holds the charts.
func reconcileServices(ctx *cli.Context) int {
	return runWorkstationArgoCD(ctx, "services-reconcile")
}
