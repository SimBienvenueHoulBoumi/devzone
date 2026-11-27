package command

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// workspaceCommand runs every "devzone workspace" subcommand in Go (#712,
// #754, #781, #883, #901, #934): start, update, status, stop, shell, vscode,
// copy-to, copy-from, clone, ports, services, argocd and egress. Nothing is
// delegated to bash any more, so an unknown word is refused here with the message
// of the former entry point. Extra words are ignored where the shell ignored
// them (status, stop, vscode, shell), and the watcher commands (ports start,
// loop, agent) stay internal, not listed in the help.
func workspaceCommand(ctx *cli.Context) int {
	args := ctx.Args
	out := ctx.Out
	errOut := ctx.Err
	if len(args) == 0 {
		fmt.Fprint(out, workspaceHelp)
		return 0
	}
	switch args[0] {
	case "help", "-h", "--help":
		fmt.Fprint(out, workspaceHelp)
		return 0
	case "start":
		return startWorkspace(ctx)
	case "deploy":
		return workspaceDeploy(ctx)
	// "update" moves the workspace to a release in Go (#934): the deploy and
	// the service reconciliation reuse the Argo CD and helm libraries.
	case "update":
		return updateWorkspace(ctx)
	// "egress" moves to Go too (#934): the settings and the redeploy at the
	// running image reuse the same Argo CD and helm libraries as update.
	case "egress":
		return egressCommand(ctx)
	// The internal guard and wait commands are called by the start path; they
	// have no user-facing help.
	case "agents-guard":
		if len(args) == 1 {
			return agentsGuardCommand(ctx)
		}
	// The zombie report reads the pod's /proc (#973); it is not in the help.
	case "zombies":
		if len(args) == 1 {
			return zombiesCommand(ctx)
		}
	case "wait":
		sub := &cli.Context{Args: args[1:], Out: out, Err: errOut, Stdin: ctx.Stdin, Runner: ctx.Runner}
		return podWaitCommand(sub)
	case "clone":
		url, name := "", ""
		if len(args) == 2 || len(args) == 3 {
			url = args[1]
		}
		if len(args) == 3 {
			name = args[2]
		}
		return workspace.Clone(commandWorkspaceRunner, workspace.Identity, url, name, out, errOut)
	case "copy-to", "copy-from":
		folder := ""
		if len(args) >= 2 {
			folder = args[1]
		}
		if args[0] == "copy-to" {
			return workspace.CopyTo(commandWorkspaceRunner, workspace.Origin, folder, out, errOut)
		}
		return workspace.CopyFrom(commandWorkspaceRunner, folder, out, errOut)
	case "status":
		return workspace.Status(commandWorkspaceRunner, out, errOut)
	case "stop":
		return workspaceStopCommand(ctx)
	case "vscode":
		return workspace.VSCode(out)
	case "shell":
		return workspace.Shell(commandWorkspaceRunner, os.Stdin, out, errOut)
	// "services" alone and "services status" run in Go (#781); the other forms
	// (enable, disable, seed, unknown words) are handled by commandServices.
	case "services":
		if len(args) == 1 || (len(args) == 2 && args[1] == "status") {
			return workspace.ServicesStatus(commandWorkspaceRunner, out)
		}
		return commandServices(args, out, errOut)
	// Every "argocd" form runs in Go (#883): status reads the cluster, init,
	// apply and app use the GitOps library, and reconcile follows the
	// declarations. An unknown word gets the message of the former shell.
	case "argocd":
		sub := &cli.Context{Args: args[1:], Out: out, Err: errOut, Runner: ctx.Runner}
		if len(args) == 1 {
			return workspace.ArgoCDStatus(argoCDRunner(sub), modulesFile(), out)
		}
		switch args[1] {
		case "status":
			return workspace.ArgoCDStatus(argoCDRunner(sub), modulesFile(), out)
		case "reconcile":
			return argoCDReconcileCommand(sub)
		case "init", "app":
			return runWorkstationArgoCD(sub, args[1:]...)
		case "apply":
			if !commandArgoCDInstalled(argoCDRunner(sub)) {
				fmt.Fprintln(errOut, "✖ Argo CD not installed: devzone workspace services enable argocd")
				return 1
			}
			return argoCDReconcileCommand(sub)
		default:
			return workspaceArgoCDUnknown(errOut)
		}
	// "ports" alone is status, as ports does in the former entry point; the
	// watcher commands start, loop and agent stay internal.
	case "ports":
		if len(args) == 1 || (len(args) == 2 && args[1] == "status") {
			return workspace.PortsStatus(out)
		}
		if len(args) == 2 {
			switch args[1] {
			case "start":
				return commandPortsStart(out, errOut)
			case "stop":
				return workspace.PortsStop()
			case "enable":
				return portsEnableForUser(out, errOut)
			case "disable":
				return portsDisableForUser(out, errOut)
			case "loop":
				return workspace.PortsLoop(workspace.PortsStep())
			case "agent":
				return commandPortsAgent(out, errOut)
			}
		}
		return workspacePortsUnknown(errOut)
	}
	return workspaceUnknown(errOut, args[0])
}
