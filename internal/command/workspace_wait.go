package command

import (
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// runPodWaitWith waits with an injected runner. A failed image pull removes the
// chart silently, as the shell wait redirected the undeploy output, so only the
// wait messages reach the user.
func runPodWaitWith(r workspace.Runner, image string, out, errOut io.Writer) int {
	return workspace.WaitForPod(r, image, out, errOut, func() int {
		return workspace.Undeploy(r, io.Discard, io.Discard)
	})
}

// runPodWait waits with the runner of the workstation, as the shell did.
func runPodWait(image string, out, errOut io.Writer) int {
	return runPodWaitWith(workspace.ExecRunner{}, image, out, errOut)
}

// commandPodWait is replaceable so a test can check the routing and the status
// of the internal wait command without a cluster.
var commandPodWait = runPodWait

// podWaitCommand handles "workspace wait <image>", called by the shell start
// path with the image the chart is deploying. Its only argument is mandatory.
func podWaitCommand(ctx *cli.Context) int {
	errOut := ctx.Err
	if errOut == nil {
		errOut = io.Discard
	}
	if len(ctx.Args) != 1 || ctx.Args[0] == "" {
		fmt.Fprintln(errOut, "✖ usage: devzone workspace wait <image>")
		return 2
	}
	out := ctx.Out
	if out == nil {
		out = io.Discard
	}
	return commandPodWait(ctx.Args[0], out, errOut)
}
