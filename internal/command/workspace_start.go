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

// argoCDRequired writes the Argo CD-required message on errOut and returns 1:
// there is no direct chart fallback anymore. deployWorkspaceAt writes the same
// message for "workspace update".
func argoCDRequired(errOut io.Writer) int {
	fmt.Fprintln(errOut, "devzone : workspace : Argo CD is required but not running,")
	fmt.Fprintln(errOut, "please run: devzone enable argocd")
	return 1
}

// startWorkspace runs the whole "workspace start" in Go, as start_workspace did
// in manage/workspace.sh: the cluster is checked first, the image is parsed,
// Argo CD is enabled when wanted, the chart is deployed through its Application,
// the declarations are reconciled, the pod is awaited, the agent guard runs and
// the port watcher starts. Without Argo CD there is no direct helm fallback: a
// missing or unstartable Argo CD stops the start. The automatic start of the
// watcher is added by the command layer after a success.
func startWorkspace(ctx *cli.Context) int {
	if reason, ready := commandKubeReady(commandWorkspaceRunner, true); !ready {
		fmt.Fprintln(ctx.Err, reason)
		return 1
	}
	argoFailed := false
	env := workspace.StartEnv{
		Runner: commandWorkspaceRunner, Modules: modulesFile(),
		Out: ctx.Out, ErrOut: ctx.Err,
		Ready: func() (string, bool) { return "", true },
		Deploy: func(repository, tag string, withImage bool) int {
			if argoFailed {
				return argoCDRequired(ctx.Err)
			}
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
				argoFailed = true
			}
		}
	} else {
		return argoCDRequired(ctx.Err)
	}
	return env.Run(ctx.Args[1:])
}

// startWorkspaceDeploy declares the workspace as an Argo CD Application when
// Argo CD holds the charts. When the deploy hands off (status 3) because Argo
// CD is not running, the start stops: there is no direct chart installation
// anymore.
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
	return argoCDRequired(ctx.Err)
}
