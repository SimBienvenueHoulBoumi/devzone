package podcmd

import (
	"context"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/cluster"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/output"
)

// runCluster handles "cluster clean" in Go and delegates every other cluster
// command to the shell, exactly as before the migration.
func runCluster(ctx *cli.Context) int {
	if len(ctx.Args) == 0 || ctx.Args[0] != "clean" {
		return delegate(append([]string{"cluster"}, ctx.Args...), ctx.Out, ctx.Err)
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
