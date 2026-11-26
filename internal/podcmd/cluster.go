package podcmd

import (
	"context"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/cluster"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/output"
)

// runCluster handles the services cluster commands in Go: "clean" and the
// show/change command. A "use" subcommand still belongs to another command.
func runCluster(ctx *cli.Context) int {
	if len(ctx.Args) > 0 && ctx.Args[0] == "use" {
		return delegate(append([]string{"cluster"}, ctx.Args...), ctx.Out, ctx.Err)
	}
	if len(ctx.Args) == 0 || ctx.Args[0] != "clean" {
		return cluster.Change(context.Background(), manageOptions(ctx), ctx.Args)
	}
	errOut := ctx.Err
	if errOut == nil {
		errOut = io.Discard
	}
	var opts cluster.Options
	opts.Runner = ctx.Runner
	opts.Out = ctx.Out
	opts.Err = errOut
	for _, arg := range ctx.Args[1:] {
		switch arg {
		case "--dry-run":
			opts.DryRun = true
		case "--quiet":
			opts.Quiet = true
		default:
			output.Fail(errOut, "cluster clean: unknown argument: %s", arg)
			return 2
		}
	}
	report, err := cluster.Clean(context.Background(), opts)
	if err != nil {
		output.Fail(errOut, "cluster clean: %v", err)
		return 1
	}
	return report.Code
}
