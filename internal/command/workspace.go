package command

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// workspaceCommand runs "devzone workspace status" and "devzone workspace stop" in
// Go (#712). Any other subcommand, and any subcommand with extra words, is delegated
// to bash unchanged, as the bash entry point handles them (renamed words, extra
// arguments). When the Argo CD Application holds the workspace, stop is delegated too.
func workspaceCommand(args []string, out, errOut io.Writer) int {
	if len(args) == 1 {
		switch args[0] {
		case "status":
			return workspace.Status(workspace.ExecRunner{}, out, errOut)
		case "stop":
			fallback := func() int { return delegate([]string{"workspace", "stop"}, out, errOut) }
			return workspace.Stop(workspace.ExecRunner{}, out, errOut, fallback)
		}
	}
	return delegate(append([]string{"workspace"}, args...), out, errOut)
}
