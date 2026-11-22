package command

import (
	"io"
	"os"
	"runtime"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// workspaceCommand runs the "devzone workspace" subcommands status, stop, vscode
// and shell in Go (#712), copy-to and copy-from with one folder argument (#754),
// clone with a url and an optional name (#754), ports without a word (status)
// or with start, status or stop (#781), and services without a word or with the
// word status (#781, lot A1.3a); "ports loop" is the internal command of the
// watcher that "ports start" launches, not listed in the help. On Windows
// the watcher does not exist in Go: "ports start" stays delegated to bash there.
// Any other subcommand, and any subcommand with extra words, is delegated to bash
// unchanged, as the bash entry point handles them (renamed words, extra
// arguments). When the Argo CD Application holds the workspace, stop is
// delegated too. shell gets the terminal of the user as its standard input.
func workspaceCommand(args []string, out, errOut io.Writer) int {
	if len(args) == 2 || len(args) == 3 {
		if args[0] == "clone" {
			name := ""
			if len(args) == 3 {
				name = args[2]
			}
			return workspace.Clone(workspace.ExecRunner{}, workspace.Identity, args[1], name, out, errOut)
		}
	}
	if len(args) == 2 {
		switch args[0] {
		case "copy-to":
			return workspace.CopyTo(workspace.ExecRunner{}, workspace.Origin, args[1], out, errOut)
		case "copy-from":
			return workspace.CopyFrom(workspace.ExecRunner{}, args[1], out, errOut)
		}
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
	}
	// "ports" alone is status, as ports does in the bash entry point.
	if len(args) > 0 && args[0] == "ports" {
		if len(args) == 1 || (len(args) == 2 && args[1] == "status") {
			return workspace.PortsStatus(out)
		}
		if len(args) == 2 && args[1] == "stop" {
			return workspace.PortsStop()
		}
		if len(args) == 2 && runtime.GOOS != "windows" {
			switch args[1] {
			case "start":
				return workspace.PortsStart(out, errOut)
			case "loop":
				return workspace.PortsLoop(workspace.PortsStep())
			}
		}
	}
	return delegate(append([]string{"workspace"}, args...), out, errOut)
}
