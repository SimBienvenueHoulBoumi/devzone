package command

import (
	"fmt"
	osexec "os/exec"
	"runtime"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
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

// startWorkspace delegates the cluster work of "devzone workspace start" to the
// shell entry point, then installs the automatic start of the port watcher in
// Go. A successful start stays successful when there is no service manager: Go
// says so in one line. An enable that fails afterwards is only a warning, since
// the workspace is already running. This is why the shell workspace command
// does not grow a new step: when the Go program is absent, only the cluster
// work runs.
func startWorkspace(ctx *cli.Context) int {
	args := append([]string{"workspace"}, ctx.Args...)
	if status := delegate(args, ctx.Out, ctx.Err); status != 0 {
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
