package podcmd

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runArgocd handles the "argocd" pod command in Go with the same resolved
// folders as postgres: the devzone root for state and secrets, the shell entry
// point folder for the charts and the shared libraries, never the current folder.
func runArgocd(ctx *cli.Context) int {
	opts := argocd.Options{
		Runner:   ctx.Runner,
		Out:      ctx.Out,
		Err:      ctx.Err,
		Root:     devzoneRoot(),
		CodeRoot: codeRoot(),
	}
	return argocd.Run(context.Background(), ctx.Args, ctx.Out, ctx.Err, opts)
}
