package command

import (
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// commandKubeReady and commandArgoCDInstalled are injectable so a test can
// exercise the routing of start without a cluster, a fake kubectl or a shell.
var (
	commandKubeReady       = workspace.KubeReady
	commandArgoCDInstalled = workspace.ArgoCDInstalled
)

// The actions of a workspace start are injectable, so a test drives the whole
// command without a cluster, a chart, a watcher or a GitOps repository.
var (
	commandStartEnableArgoCD = func(ctx *cli.Context) int {
		return commandServices([]string{"services", "enable", "argocd"}, ctx.Out, ctx.Err)
	}
	commandStartDeploy    = startWorkspaceDeploy
	commandStartReconcile = argoCDReconcileCommand
	commandStartWait      = func(r workspace.Runner, image string, out, errOut io.Writer) int {
		return runPodWaitWith(r, image, out, errOut)
	}
	commandStartGuard = func(r workspace.Runner, out io.Writer) {
		workspace.AgentsGuard(r, out)
	}
	commandStartPorts = func(out, errOut io.Writer) int {
		return commandPortsStart(out, errOut)
	}
)

// startWorkspace runs the whole "workspace start" in Go, as start_workspace did
// in manage/workspace.sh: the cluster is checked first, the image is parsed,
// Argo CD is enabled when wanted, the chart is deployed through its Application
// or directly by helm, the declarations are reconciled, the pod is awaited, the
// agent guard runs and the port watcher starts. The automatic start of the
// watcher is added by the command layer after a success.
func startWorkspace(ctx *cli.Context) int {
	if reason, ready := commandKubeReady(commandWorkspaceRunner, true); !ready {
		fmt.Fprintln(ctx.Err, reason)
		return 1
	}
	env := workspace.StartEnv{
		Runner: commandWorkspaceRunner, Modules: modulesFile(),
		Out: ctx.Out, ErrOut: ctx.Err,
		Ready: func() (string, bool) { return "", true },
		Deploy: func(repository, tag string, withImage bool) int {
			return commandStartDeploy(ctx, repository, tag, withImage)
		},
		Reconcile: func() int { return commandStartReconcile(ctx) },
		Wait: func(image string) int {
			return commandStartWait(commandWorkspaceRunner, image, ctx.Out, ctx.Err)
		},
		Guard:      func() { commandStartGuard(commandWorkspaceRunner, ctx.Out) },
		PortsStart: func() int { return commandStartPorts(ctx.Out, ctx.Err) },
	}
	if workspace.ArgoCDWanted(modulesFile()) {
		env.EnableArgoCD = func() {
			if commandStartEnableArgoCD(ctx) != 0 {
				fmt.Fprintln(ctx.Err, "⚠ Argo CD not installed: the workspace is deployed with helm directly (devzone workspace services enable argocd to retry)")
			}
		}
	}
	return env.Run(ctx.Args[1:])
}

// startWorkspaceDeploy declares the workspace as an Argo CD Application when
// Argo CD holds the charts, and falls back to the direct chart installation when
// the deploy hands off (status 3), as start_workspace did with workspace_deploy
// then workspace_helm_deploy.
func startWorkspaceDeploy(ctx *cli.Context, repository, tag string, withImage bool) int {
	with := ""
	if withImage {
		with = "yes"
	}
	deployCtx := &cli.Context{
		Args: []string{"deploy", repository, tag, with},
		Out:  ctx.Out, Err: ctx.Err, Runner: ctx.Runner,
	}
	if code := workspaceDeploy(deployCtx); code != 3 {
		return code
	}
	return workspace.HelmDeploy(commandWorkspaceRunner, modulesFile(), repository, tag, withImage, ctx.Out, ctx.Err)
}
