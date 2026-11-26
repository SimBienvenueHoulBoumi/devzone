package podcmd

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/catalog"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runCatalog handles "devzone catalog" in Go with the pod runner and the
// resolved folders, so the state, the charts and the apps are the ones of this
// devzone instance rather than those of the current folder.
func runCatalog(ctx *cli.Context) int {
	opts := catalog.Options{
		Runner:   ctx.Runner,
		Out:      ctx.Out,
		Err:      ctx.Err,
		Stdin:    ctx.Stdin,
		CodeRoot: codeRoot(),
		Root:     devzoneRoot(),
	}
	return catalog.Run(context.Background(), opts, ctx.Args)
}

// runCatalogWatcher handles "devzone catalog-watcher", the single background
// process that applies the catalog when .devzone.modules changes.
func runCatalogWatcher(ctx *cli.Context) int {
	opts := catalog.Options{
		Runner:   ctx.Runner,
		Out:      ctx.Out,
		Err:      ctx.Err,
		CodeRoot: codeRoot(),
		Root:     devzoneRoot(),
	}
	return catalog.WatcherRun(context.Background(), opts, ctx.Args)
}
