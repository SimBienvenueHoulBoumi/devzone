package command

import (
	"context"
	"errors"
	"path/filepath"
	"sort"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

func collectUninstallPlan(ctx context.Context, runner exec.Runner, root, instance string) (uninstallPlan, error) {
	kubeCtx, err := servicesContext(ctx, runner, root)
	if errors.Is(err, errNoServicesCluster) {
		return uninstallPlan{workspaceKept: filepath.Join(root, "workspace"), noCluster: true, devzoneFiles: listDevzoneFiles(root)}, nil
	}
	if err != nil {
		return uninstallPlan{}, err
	}
	plan := uninstallPlan{workspaceKept: filepath.Join(root, "workspace"), kubeContext: kubeCtx}
	namespaces, err := kubectlLines(ctx, runner, kubeCtx, "get", "namespaces", "-l", managedByLabel, "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
	if err != nil {
		return uninstallPlan{}, err
	}
	owned, doubtful := filterInstanceNamespaces(namespaces, instance)
	plan.namespaces = owned
	plan.keptObjects = append(plan.keptObjects, doubtful...)
	apps, err := kubectlLines(ctx, runner, kubeCtx, "get", "applications.argoproj.io", "-A", "-l", managedByLabel, "-o", "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{\"\\n\"}{end}")
	switch {
	case err == nil:
		owned, doubtful := filterInstanceApps(apps, instance)
		plan.applications = owned
		plan.keptObjects = append(plan.keptObjects, doubtful...)
	case errors.Is(err, errMissingResourceType):
		// Argo CD is not installed in this cluster: no Applications to remove.
	default:
		return uninstallPlan{}, err
	}
	accounts, err := kubectlLines(ctx, runner, kubeCtx, "get", "serviceaccounts", "-A", "--field-selector", "metadata.name=devzone-services-admin", "-o", "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{\"\\n\"}{end}")
	if err != nil {
		return uninstallPlan{}, err
	}
	owned, doubtful = filterTempAccounts(accounts, instance)
	plan.tempAccounts = owned
	plan.keptObjects = append(plan.keptObjects, doubtful...)
	plan.devzoneFiles = listDevzoneFiles(root)
	sort.Strings(plan.namespaces)
	sort.Strings(plan.applications)
	sort.Strings(plan.tempAccounts)
	sort.Strings(plan.devzoneFiles)
	sort.Strings(plan.keptObjects)
	return plan, nil
}
