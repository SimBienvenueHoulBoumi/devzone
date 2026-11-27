package command

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/hostcheck"
)

const managedByLabel = "app.kubernetes.io/managed-by=devzone"

// errMissingResourceType marks a kubectl list failure caused by a resource the
// cluster does not know, which happens when the Argo CD CRD is not installed.
var errMissingResourceType = errors.New("resource type not installed in the cluster")

// uninstallCommand removes what this devzone instance created. On the host: the
// containers, images and volumes of this folder, the kind clusters and labeled
// containers of the instance, the metrics-server devzone installed. In the
// cluster: the objects labeled managed-by=devzone that belong to the instance.
// workspace/ and the other instances are kept. Nothing is removed before the
// plan is printed and confirmed (--yes or CONFIRM=yes).
func uninstallCommand(ctx *cli.Context) int {
	root, err := uninstallRoot()
	if err != nil {
		fmt.Fprintf(ctx.Err, "devzone: %v\n", err)
		return 1
	}
	if _, err := os.Stat(filepath.Join(root, ".devcontainer")); err != nil {
		fmt.Fprintln(ctx.Err, "✖ Not a devzone folder (.devcontainer/ not found here).")
		return 1
	}
	if script := legacyUninstaller(root); script != "" {
		return runLegacyUninstaller(ctx, script)
	}
	yes, bad := parseUninstallArgs(ctx.Args)
	if bad != "" {
		fmt.Fprintln(ctx.Err, bad)
		return 1
	}
	keep, err := uninstallKeep()
	if err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	runner := ctx.Runner
	if runner == nil {
		runner = exec.ExecRunner{}
	}
	bg := context.Background()
	// Host engine first: without it every call would show its raw error
	if !hostcheck.Ready(bg, runner, engineCommand(), uninstallCommandName(), ctx.Err) {
		return 1
	}
	instance := devzoneInstance()
	host, err := collectHostPlan(bg, runner, root, instance, keep, insideContainer())
	if err != nil {
		fmt.Fprintf(ctx.Err, "✖ %v\n", err)
		return 1
	}
	kube, err := collectUninstallPlan(bg, runner, root, instance)
	if err != nil {
		fmt.Fprintf(ctx.Err, "devzone: %v\n", err)
		return 1
	}
	printUninstallPlan(ctx.Out, root, instance, kube, host)
	for _, ns := range kube.namespaces {
		if ns == "devzone-workspace" {
			fmt.Fprintln(ctx.Out, "⚠ namespace devzone-workspace holds the pod volumes: deleting it loses the pod data.")
			break
		}
	}
	status := 0
	if kube.empty() && host.count() == 0 {
		fmt.Fprintln(ctx.Out, "✔ Nothing to remove.")
	} else {
		proceed, code := confirmUninstall(ctx, yes)
		if !proceed {
			return code
		}
		status = removeAll(bg, runner, host, kube, ctx.Out, ctx.Err)
	}
	// The state files go only once everything else was removed, so a retry can
	// still finish the job after a failure
	if status == 0 {
		status = removeStateFiles(kube.devzoneFiles, ctx.Out, ctx.Err)
	}
	// The automatic start of the port watcher is retired with the uninstall, as
	// the design of the ports commands of #901 says.
	if disable := retirePortsAutoStartAfterUninstall(ctx.Out, ctx.Err); disable != 0 {
		status = disable
	}
	printRemains(ctx.Out, root, host)
	return status
}

// removeAll removes the planned resources in the order of the shell uninstaller:
// the containers, images and volumes of the folder, the metrics-server, the
// Kubernetes objects, then the kind clusters and labeled containers. A failure is
// reported and the others go on; the result is 1 when one of them failed.
func removeAll(ctx context.Context, runner exec.Runner, host hostPlan, kube uninstallPlan, out, errOut io.Writer) int {
	d := engineCall{ctx: ctx, runner: runner, cmd: engineCommand()}
	status := removeHostFirst(d, host, out, errOut)
	status = max(status, removeMetricsServers(ctx, runner, host, out, errOut))
	status = max(status, applyUninstallPlan(ctx, runner, out, errOut, kube))
	return max(status, removeHostLast(d, host, out, errOut))
}
