package command

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// applyUninstallPlan deletes the Kubernetes objects of the plan, in the order
// that keeps Applications before their namespaces. Failures are reported and do
// not stop the other deletions; it returns 1 when one failed.
func applyUninstallPlan(ctx context.Context, runner exec.Runner, out, errOut io.Writer, plan uninstallPlan) int {
	status := 0
	for _, app := range plan.applications {
		parts := strings.SplitN(app, "/", 2)
		if len(parts) != 2 {
			continue
		}
		res, err := runner.Run(ctx, "kubectl", []string{"--context", plan.kubeContext, "-n", parts[0], "delete", "application.argoproj.io", parts[1], "--ignore-not-found"}, exec.Opts{})
		if err != nil || res.Code != 0 {
			fmt.Fprintf(errOut, "✖ Argo CD Application %s: %v\n", app, err)
			status = 1
		} else {
			fmt.Fprintf(out, "✔ Argo CD Application removed: %s\n", app)
		}
	}
	for _, sa := range plan.tempAccounts {
		parts := strings.SplitN(sa, "/", 2)
		if len(parts) != 2 {
			continue
		}
		res, err := runner.Run(ctx, "kubectl", []string{"--context", plan.kubeContext, "-n", parts[0], "delete", "serviceaccount", parts[1], "--ignore-not-found"}, exec.Opts{})
		if err != nil || res.Code != 0 {
			fmt.Fprintf(errOut, "✖ temporary account %s: %v\n", sa, err)
			status = 1
		} else {
			fmt.Fprintf(out, "✔ temporary account removed: %s\n", sa)
		}
	}
	for _, ns := range plan.namespaces {
		res, err := runner.Run(ctx, "kubectl", []string{"--context", plan.kubeContext, "delete", "namespace", ns, "--ignore-not-found"}, exec.Opts{})
		if err != nil || res.Code != 0 {
			fmt.Fprintf(errOut, "✖ namespace %s: %v\n", ns, err)
			status = 1
		} else {
			fmt.Fprintf(out, "✔ namespace removed: %s\n", ns)
		}
	}
	return status
}
