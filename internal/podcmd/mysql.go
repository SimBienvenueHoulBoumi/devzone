package podcmd

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/mysql"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runMysql handles every "mysql" subcommand in Go with the pod runner and the
// shell entry point folder for the shared libraries and charts.
func runMysql(ctx *cli.Context) int {
	opts := mysql.Options{
		Runner:   ctx.Runner,
		Out:      ctx.Out,
		Err:      ctx.Err,
		Stdin:    ctx.Stdin,
		CodeRoot: codeRoot(),
		Root:     devzoneRoot(),
	}
	return mysql.Run(context.Background(), opts, ctx.Args)
}
