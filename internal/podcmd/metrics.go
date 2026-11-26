package podcmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// runMetrics keeps "devzone metrics" working: with Argo CD active the
// dependency becomes an Application from its official source at a pinned
// version; otherwise the existing shell installer runs unchanged.
func runMetrics(ctx *cli.Context) int {
	if !metricsHeldByArgoCD(ctx) {
		return delegate(append([]string{"metrics"}, ctx.Args...), ctx.Out, ctx.Err)
	}
	fmt.Fprintln(ctx.Out, "▶ metrics-server through Argo CD (official chart, pinned version)")
	opts := argocd.Options{
		Runner: ctx.Runner, Out: ctx.Out, Err: ctx.Err,
		Root: devzoneRoot(), CodeRoot: codeRoot(),
	}
	return argocd.Run(context.Background(),
		append([]string{"dependency", "metrics-server", "on"}, ctx.Args...), ctx.Out, ctx.Err, opts)
}

// metricsHeldByArgoCD reports whether the module is on and Argo CD is
// installed, as argocd_active does in the workspace entry point.
func metricsHeldByArgoCD(ctx *cli.Context) bool {
	root := devzoneRoot()
	state := os.Getenv("DEVZONE_STATE")
	if state == "" {
		state = filepath.Join(root, ".devzone.modules")
	}
	data, err := os.ReadFile(state)
	if err != nil {
		return false
	}
	wanted := true
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "argocd=off" {
			wanted = false
		}
	}
	if !wanted {
		return false
	}
	res, err := ctx.Runner.Run(context.Background(), "kubectl",
		[]string{"--context", "devzone", "get", "namespace", "devzone-argocd"}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return false
	}
	return true
}
