package podcmd

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/gitlab/e2e"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runTestGitlab handles the e2e command in Go: the devzone root comes from
// devzoneRoot(), as for postgres, never from the current directory.
func runTestGitlab(ctx *cli.Context) int {
	opts := e2e.Options{
		Runner: ctx.Runner,
		Out:    ctx.Out,
		Err:    ctx.Err,
		Root:   devzoneRoot(),
	}
	return e2e.Run(context.Background(), ctx.Args, opts)
}
