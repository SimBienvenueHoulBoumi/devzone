package podcmd

import (
	"context"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/postgres"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runPostgres handles every "postgres" subcommand in Go with the pod runner
// and the shell entry point folder for the shared password and kube libraries.
func runPostgres(ctx *cli.Context) int {
	opts := postgres.Options{
		Runner:   ctx.Runner,
		Out:      ctx.Out,
		Err:      ctx.Err,
		Stdin:    ctx.Stdin,
		CodeRoot: codeRoot(),
	}
	return postgres.Run(context.Background(), opts, ctx.Args)
}

// codeRoot returns the folder of the devzone shell entry point, which holds
// the charts and the shell libraries the Go domains still call.
func codeRoot() string {
	script := os.Getenv("DEVZONE_POD_SCRIPT")
	if script != "" {
		if info, err := os.Stat(script); err == nil && info.Mode().IsRegular() {
			return filepath.Dir(script)
		}
	}
	info, err := os.Stat(defaultScript)
	if err == nil && info.Mode().IsRegular() {
		return filepath.Dir(defaultScript)
	}
	return ""
}
