package podcmd

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/gitlab"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runGitlab handles every "gitlab" subcommand in Go with the pod runner and
// the shell entry point folder for the shared libraries and charts.
func runGitlab(ctx *cli.Context) int {
	opts := gitlab.Options{
		Runner: ctx.Runner,
		Out:    ctx.Out,
		Err:    ctx.Err,
		Root:   devzoneRoot(),
	}
	return gitlab.Run(context.Background(), ctx.Args, opts)
}
