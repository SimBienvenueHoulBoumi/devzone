package podcmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// buildRefusal answers a caller that is not in the Kubernetes workspace pod:
// the BuildKit sidecar of that pod is the builder the pod uses, and a caller on
// a workstation has another builder, reached by another command.
func buildRefusal(ctx *cli.Context) int {
	fmt.Fprintln(ctx.Err, "devzone build: only in the Kubernetes workspace pod")
	return 1
}

// runBuild handles the build command of the pod in Go: it runs the BuildKit
// client of the workspace sidecar in the foreground, with the folder and the
// optional image tag given by the caller, and returns the status of buildctl.
func runBuild(ctx *cli.Context) int {
	if os.Getenv("DEVZONE_WORKSPACE") != "kubernetes" {
		return buildRefusal(ctx)
	}
	args := ctx.Args
	if len(args) == 0 {
		fmt.Fprintln(ctx.Err, "devzone build: usage: devzone build <directory> [--tag <name>]")
		return 1
	}
	dir := args[0]
	tag := ""
	rest := args[1:]
	for i := 0; i < len(rest); i++ {
		if rest[i] == "--tag" {
			if i+1 >= len(rest) {
				fmt.Fprintln(ctx.Err, "devzone build: --tag requires a name")
				return 1
			}
			tag = rest[i+1]
			i++
			continue
		}
		fmt.Fprintf(ctx.Err, "devzone build: unknown argument: %s\n", rest[i])
		return 1
	}
	if !isDirectory(dir) {
		fmt.Fprintf(ctx.Err, "devzone build: directory not found: %s\n", dir)
		return 1
	}
	if _, err := os.Stat(filepath.Join(dir, "Dockerfile")); err != nil {
		fmt.Fprintf(ctx.Err, "devzone build: Dockerfile not found in: %s\n", dir)
		return 1
	}
	output := "type=cacheonly"
	if tag != "" {
		output = "type=image,name=" + tag + ",push=false"
	}
	addr := os.Getenv("BUILDKIT_HOST")
	if addr == "" {
		addr = "tcp://127.0.0.1:1234"
	}
	res, err := ctx.Runner.Run(context.Background(), "buildctl", []string{
		"--addr", addr,
		"build",
		"--frontend", "dockerfile.v0",
		"--local", "context=" + dir,
		"--local", "dockerfile=" + dir,
		"--output", output,
	}, exec.Opts{})
	if err != nil {
		return 1
	}
	return res.Code
}
