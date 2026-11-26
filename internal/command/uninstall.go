package command

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

const managedByLabel = "app.kubernetes.io/managed-by=devzone"

// errMissingResourceType marks a kubectl list failure caused by a resource the
// cluster does not know, which happens when the Argo CD CRD is not installed.
var errMissingResourceType = errors.New("resource type not installed in the cluster")

// uninstallCommand removes Kubernetes objects created by this devzone instance.
// It only touches objects carrying the devzone managed-by label or the instance
// label, keeps workspace/, and asks for confirmation unless --yes is given.
func uninstallCommand(ctx *cli.Context) int {
	root := os.Getenv("DEVZONE_ROOT")
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			fmt.Fprintf(ctx.Err, "devzone: %v\n", err)
			return 1
		}
	}
	if _, err := os.Stat(filepath.Join(root, ".devcontainer")); err != nil {
		fmt.Fprintln(ctx.Err, "✖ Not a devzone folder (.devcontainer/ not found here).")
		return 1
	}
	yes := false
	for _, a := range ctx.Args {
		if a == "--yes" {
			yes = true
			continue
		}
		fmt.Fprintf(ctx.Err, "✖ unknown option: %s (devzone uninstall [--yes])\n", a)
		return 1
	}
	instance := devzoneInstance()
	runner := ctx.Runner
	if runner == nil {
		runner = exec.ExecRunner{}
	}
	plan, err := collectUninstallPlan(context.Background(), runner, root, instance)
	if err != nil {
		fmt.Fprintf(ctx.Err, "devzone: %v\n", err)
		return 1
	}
	printUninstallPlan(ctx.Out, plan)
	if plan.empty() {
		fmt.Fprintln(ctx.Out, "✔ Nothing to remove.")
		return retirePortsAutoStart(ctx.Out, ctx.Err)
	}
	for _, ns := range plan.namespaces {
		if ns == "devzone-workspace" {
			fmt.Fprintln(ctx.Out, "⚠ namespace devzone-workspace holds the pod volumes: deleting it loses the pod data.")
			break
		}
	}
	if !yes {
		if !isTerminal(ctx.Stdin) {
			fmt.Fprintln(ctx.Err, "✖ Cannot confirm without a terminal: devzone uninstall --yes")
			return 1
		}
		fmt.Fprint(ctx.Out, "Permanently remove? Type yes: ")
		answer, _ := bufio.NewReader(ctx.Stdin).ReadString('\n')
		if strings.TrimSpace(answer) != "yes" {
			fmt.Fprintln(ctx.Out, "Canceled: nothing was removed.")
			return 0
		}
	}
	status := applyUninstallPlan(context.Background(), runner, ctx.Out, ctx.Err, plan)
	// The automatic start of the port watcher is retired with the uninstall, as
	// the design of the ports commands of #901 says.
	if disable := retirePortsAutoStart(ctx.Out, ctx.Err); disable != 0 {
		status = disable
	}
	return status
}

// devzoneInstance returns the instance name for this devzone folder. It prefers
// DEVZONE_INSTANCE, then DEVZONE_VOLUMES, then the default "devzone".
func devzoneInstance() string {
	for _, k := range []string{"DEVZONE_INSTANCE", "DEVZONE_VOLUMES"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return "devzone"
}

type uninstallPlan struct {
	kubeContext   string
	namespaces    []string
	applications  []string
	tempAccounts  []string
	devzoneFiles  []string
	keptObjects   []string
	workspaceKept string
}

func (p uninstallPlan) empty() bool {
	return len(p.namespaces) == 0 && len(p.applications) == 0 && len(p.tempAccounts) == 0 && len(p.devzoneFiles) == 0
}
