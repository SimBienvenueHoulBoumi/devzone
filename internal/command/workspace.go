package command

import (
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// workspaceCommand runs the "devzone workspace" subcommands status, stop, vscode
// and shell in Go (#712), copy-to, copy-from and clone (#754): the usage when
// the argument is missing, extra words ignored for copy-to and copy-from, ports
// without a word (status), with start, status, stop, enable or disable (#901), or
// with the internal loop and agent: these are the commands of the watcher that
// "ports start" and the automatic start launch, not listed in the help. "start"
// delegates the cluster work to bash, then enables the automatic start in Go.
// Any other subcommand is delegated to bash unchanged, as the bash entry point
// handles them (renamed words). When the Argo CD Application holds the
// workspace, stop is delegated too. shell gets the terminal of the user as its
// standard input. The watcher commands start, loop and agent run in Go on
// Windows too (#883): the relays are real processes there, as on the other
// systems. Only the automatic start stays out of Go on Windows; it belongs to
// another ticket.
func workspaceCommand(ctx *cli.Context) int {
	args := ctx.Args
	out := ctx.Out
	errOut := ctx.Err
	if len(args) >= 1 && args[0] == "start" {
		return startWorkspace(ctx)
	}
	if len(args) >= 1 && args[0] == "deploy" {
		return workspaceDeploy(ctx)
	}
	if len(args) >= 1 && args[0] == "clone" {
		url, name := "", ""
		if len(args) == 2 || len(args) == 3 {
			url = args[1]
		}
		if len(args) == 3 {
			name = args[2]
		}
		return workspace.Clone(workspace.ExecRunner{}, workspace.Identity, url, name, out, errOut)
	}
	if len(args) >= 1 && (args[0] == "copy-to" || args[0] == "copy-from") {
		folder := ""
		if len(args) >= 2 {
			folder = args[1]
		}
		if args[0] == "copy-to" {
			return workspace.CopyTo(workspace.ExecRunner{}, workspace.Origin, folder, out, errOut)
		}
		return workspace.CopyFrom(workspace.ExecRunner{}, folder, out, errOut)
	}
	if len(args) == 1 {
		switch args[0] {
		case "status":
			return workspace.Status(workspace.ExecRunner{}, out, errOut)
		case "stop":
			fallback := func() int { return delegate([]string{"workspace", "stop"}, out, errOut) }
			return workspace.Stop(workspace.ExecRunner{}, out, errOut, fallback)
		case "vscode":
			return workspace.VSCode(out)
		case "shell":
			return workspace.Shell(workspace.ExecRunner{}, os.Stdin, out, errOut)
		}
	}
	// "services" alone and "services status" run in Go (#781, lot A1.3a); the
	// other forms of the command stay delegated to bash, as services in the
	// entry point handles them (enable, disable, seed, the other words, the
	// extra words).
	if len(args) > 0 && args[0] == "services" {
		if len(args) == 1 || (len(args) == 2 && args[1] == "status") {
			return workspace.ServicesStatus(workspace.ExecRunner{}, out)
		}
		return commandServices(args, out, errOut)
	}
	// Every "argocd" form runs in Go (#883, lot 11): status reads the cluster,
	// init, apply and app use the GitOps library of internal/domain/argocd.
	if len(args) > 0 && args[0] == "argocd" {
		if len(args) == 1 || (len(args) == 2 && args[1] == "status") {
			return workspace.ArgoCDStatus(workspace.ExecRunner{}, modulesFile(), out)
		}
		switch args[1] {
		case "init", "apply", "app":
			ctx := &cli.Context{Args: args[1:], Out: out, Err: errOut}
			return runWorkstationArgoCD(ctx, args[1:]...)
		}
	}
	// "ports" alone is status, as ports does in the bash entry point.
	if len(args) > 0 && args[0] == "ports" {
		if len(args) == 1 || (len(args) == 2 && args[1] == "status") {
			return workspace.PortsStatus(out)
		}
		if len(args) == 2 && args[1] == "stop" {
			return workspace.PortsStop()
		}
		if len(args) == 2 && args[1] == "enable" {
			return portsEnableForUser(out, errOut)
		}
		if len(args) == 2 && args[1] == "disable" {
			return portsDisableForUser(out, errOut)
		}
		if len(args) == 2 {
			switch args[1] {
			case "start":
				return commandPortsStart(out, errOut)
			case "loop":
				return workspace.PortsLoop(workspace.PortsStep())
			case "agent":
				return commandPortsAgent(out, errOut)
			}
		}
	}
	return delegate(append([]string{"workspace"}, args...), out, errOut)
}
