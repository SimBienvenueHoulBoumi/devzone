package command

import (
	"fmt"
	osexec "os/exec"
	"runtime"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// portsServiceManagerAvailable tells whether this host can run the automatic
// start of the port watcher: Windows has none (#883), and a Unix host without
// systemctl or launchctl cannot manage it. It is a variable so a test can
// exercise both cases without touching a real service manager.
var portsServiceManagerAvailable = func() bool {
	if runtime.GOOS == "windows" {
		return false
	}
	tool := "systemctl"
	if runtime.GOOS == "darwin" {
		tool = "launchctl"
	}
	_, err := osexec.LookPath(tool)
	return err == nil
}

// startWorkspace runs the helm-direct form of "devzone workspace start" in Go
// when Argo CD is off and absent from the cluster; the forms that need Argo CD
// or its GitOps repository stay delegated to the shell. It then installs the
// automatic start of the port watcher in Go. A successful start stays
// successful when there is no service manager: Go says so in one line. An
// enable that fails afterwards is only a warning, since the workspace is
// already running. When the Go program is absent, the shell entry point still
// does the cluster work.
func startWorkspace(ctx *cli.Context) int {
	args := append([]string{"workspace"}, ctx.Args...)
	if !workspace.ArgoCDWanted(modulesFile()) && !workspace.ArgoCDInstalled(workspace.ExecRunner{}) {
		env := workspace.StartEnv{
			Runner: workspace.ExecRunner{}, Modules: modulesFile(),
			Out: ctx.Out, ErrOut: ctx.Err,
		}
		if status := env.Run(ctx.Args); status != 0 {
			return status
		}
	} else if status := delegate(args, ctx.Out, ctx.Err); status != 0 {
		return status
	}
	if !portsServiceManagerAvailable() {
		fmt.Fprintln(ctx.Out, "Port watcher automatic start is not available on this host (no service manager).")
		return 0
	}
	if status := commandPortsEnable(ctx.Out, ctx.Err); status != 0 {
		fmt.Fprintln(ctx.Err, "⚠ port watcher automatic start not enabled; workspace started anyway")
	}
	return 0
}
