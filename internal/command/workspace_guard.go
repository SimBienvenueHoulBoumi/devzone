package command

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// runAgentsGuard installs the idempotent guard of the agents in the pod through
// the Go implementation: the shell start path still needs that best-effort step.
func runAgentsGuard(out io.Writer) {
	workspace.AgentsGuard(workspace.ExecRunner{}, out)
}

// commandAgentsGuard is replaceable so a test can check the routing of the
// internal command without reaching a cluster.
var commandAgentsGuard = runAgentsGuard

// agentsGuardCommand handles "workspace agents-guard", called only by the shell
// start path. A guard that cannot run stays silent and always returns success.
func agentsGuardCommand(ctx *cli.Context) int {
	out := ctx.Out
	if out == nil {
		out = io.Discard
	}
	commandAgentsGuard(out)
	return 0
}
