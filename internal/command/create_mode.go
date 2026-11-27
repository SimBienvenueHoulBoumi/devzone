package command

import (
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/createmode"
)

const createModeUsage = "✖ usage: devzone create-mode choose [--kubernetes] | write <folder> <mode> | start <folder> <script>"

// createModeCommand exposes the creation decision to the shell caller that
// still copies the package (#884). Notices go to stderr on choose so stdout
// holds only the mode captured by that caller.
func createModeCommand(ctx *cli.Context) int {
	return createModeCommandWith(ctx, exec.LookPath)
}

// createModeCommandWith runs the command with an injected program lookup, so
// tests decide which programs exist without touching the process PATH.
func createModeCommandWith(ctx *cli.Context, lookPath func(string) (string, error)) int {
	if len(ctx.Args) == 0 {
		fmt.Fprintln(ctx.Err, createModeUsage)
		return 2
	}
	out, errOut := ctx.Out, ctx.Err
	if out == nil {
		out = io.Discard
	}
	if errOut == nil {
		errOut = io.Discard
	}
	runner := ctx.Runner
	if runner == nil {
		runner = fexec.ExecRunner{}
	}
	in := ctx.Stdin
	if in == nil {
		in = os.Stdin
	}
	switch ctx.Args[0] {
	case "choose":
		return createModeChoose(ctx, out, errOut, runner, in, lookPath)
	case "write":
		if len(ctx.Args) != 3 {
			fmt.Fprintln(errOut, createModeUsage)
			return 2
		}
		if err := createmode.Write(ctx.Args[1], ctx.Args[2]); err != nil {
			fmt.Fprintf(errOut, "✖ cannot write the workspace mode: %v\n", err)
			return 1
		}
		return 0
	case "start":
		if len(ctx.Args) != 3 {
			fmt.Fprintln(errOut, createModeUsage)
			return 2
		}
		session := createModeSession(out, errOut, runner, in, false, lookPath)
		if err := session.Start(ctx.Args[1], ctx.Args[2]); err != nil {
			return 1
		}
		return 0
	default:
		fmt.Fprintln(errOut, createModeUsage)
		return 2
	}
}

// createModeChoose runs the mode decision and prints the chosen mode on stdout.
func createModeChoose(ctx *cli.Context, out, errOut io.Writer, runner fexec.Runner, in io.Reader, lookPath func(string) (string, error)) int {
	if len(ctx.Args) > 2 {
		fmt.Fprintln(errOut, createModeUsage)
		return 2
	}
	option := ""
	if len(ctx.Args) == 2 {
		option = ctx.Args[1]
	}
	terminal := option == "" && (os.Getenv("DEVZONE_TERMINAL") != "" || inTerminal(in))
	session := createModeSession(errOut, errOut, runner, in, terminal, lookPath)
	mode, ok := session.Choose(option)
	if !ok {
		return 1
	}
	fmt.Fprintln(out, mode)
	return 0
}

// createModeSession builds the platform session with the given program lookup.
func createModeSession(out, errOut io.Writer, runner fexec.Runner, in io.Reader, terminal bool, lookPath func(string) (string, error)) *createmode.Session {
	return &createmode.Session{
		Runner:   runner,
		LookPath: lookPath,
		In:       in,
		Out:      out,
		Err:      errOut,
		Terminal: terminal,
	}
}
