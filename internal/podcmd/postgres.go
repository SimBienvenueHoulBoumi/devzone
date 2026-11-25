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
		Root:     devzoneRoot(),
	}
	return postgres.Run(context.Background(), opts, ctx.Args)
}

// devzoneRoot returns the devzone folder (state file, workspace/ secrets) as the
// shell did: DEVZONE_ROOT, else the parent of the shell entry point folder,
// never the current directory.
func devzoneRoot() string {
	if root := os.Getenv("DEVZONE_ROOT"); root != "" {
		return root
	}
	if code := codeRoot(); code != "" {
		return filepath.Dir(code)
	}
	return ""
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
