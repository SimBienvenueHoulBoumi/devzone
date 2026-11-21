package command

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// workspaceCommand runs "devzone workspace status" in Go (#712). Any other
// subcommand, and "devzone workspace" with extra words, is delegated to bash
// unchanged, as the bash entry point handles them.
func workspaceCommand(args []string, out, errOut io.Writer) int {
	if len(args) == 1 && args[0] == "status" {
		return workspace.Status(workspace.ExecRunner{}, out, errOut)
	}
	return delegate(append([]string{"workspace"}, args...), out, errOut)
}
