package command

import (
	"context"
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/hostcheck"
)

// hostCheckCommand is called by the shell scripts that still run (uninstall.sh)
// before any action on the host engine: "devzone host-check <command name>" exits 0 when
// Docker answers, otherwise prints the cause and exits 1. DEVZONE_DOCKER names
// the probed command (tests: simulate its absence). Not in the help: internal.
func hostCheckCommand(ctx *cli.Context) int {
	if len(ctx.Args) != 1 {
		fmt.Fprintln(ctx.Err, "✖ usage: devzone host-check <command name>")
		return 2
	}
	dockerCmd := os.Getenv("DEVZONE_DOCKER")
	if dockerCmd == "" {
		dockerCmd = "docker"
	}
	runner := ctx.Runner
	if runner == nil {
		runner = exec.ExecRunner{}
	}
	if hostcheck.Ready(context.Background(), runner, dockerCmd, ctx.Args[0], ctx.Err) {
		return 0
	}
	return 1
}
