package command

import (
	"bufio"
	"context"
	"io"
	"os"
	"os/exec"
	"runtime"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/clustermenu"
)

// clusterOfferCommand is called by manage/scripts/create-mode.sh when no cluster
// answers at creation (#884): "devzone cluster-offer" shows the menu in a
// terminal and exits 0 once a cluster was selected or created. Without a
// terminal (and DEVZONE_TERMINAL unset) nothing is asked and it exits 1. Not in
// the help: internal.
func clusterOfferCommand(ctx *cli.Context) int {
	in := ctx.Stdin
	if in == nil {
		in = os.Stdin
	}
	if os.Getenv("DEVZONE_TERMINAL") == "" && !inTerminal(in) {
		return 1
	}
	runner := ctx.Runner
	if runner == nil {
		runner = fexec.ExecRunner{}
	}
	menu := &clustermenu.Menu{
		Ctx:      context.Background(),
		Runner:   runner,
		LookPath: exec.LookPath,
		GOOS:     runtime.GOOS,
		In:       bufio.NewReader(in),
		Out:      ctx.Out,
		Err:      ctx.Err,
	}
	if menu.Offer() {
		return 0
	}
	return 1
}

// inTerminal tells whether in is a terminal: a character device that is not the
// null device (isTerminal alone accepts /dev/null, which bash "test -t 0" refuses)
func inTerminal(in io.Reader) bool {
	f, ok := in.(*os.File)
	if !ok || !isTerminal(in) {
		return false
	}
	null, err := os.Stat(os.DevNull)
	if err != nil {
		return true
	}
	info, err := f.Stat()
	return err == nil && !os.SameFile(info, null)
}
