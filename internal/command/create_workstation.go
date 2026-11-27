package command

import (
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/create"
)

// createWorkstationCommand is the Go port of devzone-create.sh (#884): the
// bash caller sources nothing and makes a single call with the folder name
// first, then the creation options; a failure exits 1, a usage error 2 only
// for a missing folder name.
func createWorkstationCommand(ctx *cli.Context) int {
	out, errOut := ctx.Out, ctx.Err
	if out == nil {
		out = io.Discard
	}
	if errOut == nil {
		errOut = io.Discard
	}
	if len(ctx.Args) == 0 {
		fmt.Fprintln(errOut, "✖ usage: devzone create-workstation <folder> [--gitops github|none|<url>] [--kubernetes]")
		return 2
	}
	target := ctx.Args[0]
	gitops, kubernetes, err := create.ParseArgs(ctx.Args[1:])
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 1
	}
	runner := ctx.Runner
	if runner == nil {
		runner = fexec.ExecRunner{}
	}
	in := ctx.Stdin
	if in == nil {
		in = os.Stdin
	}
	pkg := create.PackageRoot()
	tty := inTerminal(in)
	terminal := tty || os.Getenv("DEVZONE_TERMINAL") != ""
	opts := create.Options{
		Target:     target,
		Gitops:     gitops,
		Kubernetes: kubernetes,
		Package:    pkg,
		Version:    create.PackageVersion(pkg),
		In:         in,
		Out:        out,
		Err:        errOut,
		Runner:     runner,
		LookPath:   exec.LookPath,
		Terminal:   terminal,
		StdinTTY:   tty,
	}
	if err := create.Create(opts); err != nil {
		if err != create.ErrSilent {
			fmt.Fprintln(errOut, err)
		}
		return 1
	}
	return 0
}
