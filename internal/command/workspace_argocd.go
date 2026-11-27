package command

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// The collaborators of the workstation Argo CD commands are injectable so a
// test never asks a PATH or a cluster whether the module is installed.
var (
	commandArgoCDHoldsCharts                  = workspace.ArgoCDHoldsCharts
	commandArgoCDRunner      workspace.Runner = workspace.ExecRunner{}
)

// argoCDRunner returns the runner used to probe the Argo CD namespace and the
// charts, so that the probes stay in Go and can be replaced in a test.
func argoCDRunner(*cli.Context) workspace.Runner {
	return commandArgoCDRunner
}

// argoCDReconcileCommand applies the declarations of .argocd.conf and then the
// services held by Argo CD, as argocd_reconcile did in the workstation scripts.
// An Argo CD that is not installed is a no-op, and a refusal is reported by the
// shared library rather than by a shell fallback.
func argoCDReconcileCommand(ctx *cli.Context) int {
	if !commandArgoCDInstalled(argoCDRunner(ctx)) {
		return 0
	}
	if code := runWorkstationArgoCD(ctx, "apply"); code != 0 {
		return code
	}
	if !commandArgoCDHoldsCharts(argoCDRunner(ctx), modulesFile()) {
		return 0
	}
	return runWorkstationArgoCD(ctx, "services-reconcile")
}
