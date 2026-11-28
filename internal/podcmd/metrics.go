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

// metricsApplication installs ("on") or deletes ("off") the metrics-server
// Application through Argo CD, from its official source at a pinned version.
func metricsApplication(ctx *cli.Context, mode string) int {
	if mode == "on" {
		fmt.Fprintln(ctx.Out, "▶ metrics-server through Argo CD (official chart, pinned version)")
	}
	opts := argocd.Options{
		Runner: ctx.Runner, Out: ctx.Out, Err: ctx.Err,
		Root: devzoneRoot(), CodeRoot: codeRoot(),
	}
	return argocd.Run(context.Background(),
		[]string{"dependency", "metrics-server", mode}, ctx.Out, ctx.Err, opts)
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
	bg := context.Background()
	args := append(fexec.DevzoneContextFlag(bg, ctx.Runner, "--context"),
		"get", "namespace", "devzone-argocd")
	res, err := ctx.Runner.Run(bg, "kubectl", args, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return false
	}
	return true
}
