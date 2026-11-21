package command

import (
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// workspaceCommand runs the "devzone workspace" subcommands status, stop, vscode
// and shell in Go (#712). Any other subcommand, and any subcommand with extra
// words, is delegated to bash unchanged, as the bash entry point handles them
// (renamed words, extra arguments). When the Argo CD Application holds the
// workspace, stop is delegated too. shell gets the terminal of the user as its
// standard input.
func workspaceCommand(args []string, out, errOut io.Writer) int {
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
	return delegate(append([]string{"workspace"}, args...), out, errOut)
}
