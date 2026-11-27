package command

import (
	"fmt"
	"io"
	"path/filepath"
)

// printUninstallPlan prints the inventory and the list of what will be removed:
// the host resources of the folder and the Kubernetes objects of the instance,
// then what is kept. Nothing is removed by this function.
func printUninstallPlan(out io.Writer, root, instance string, kube uninstallPlan, host hostPlan) {
	fmt.Fprintf(out, "▶ Inventory (folder %s)\n", root)
	if host.inside {
		fmt.Fprintln(out, "ℹ Inside the container: only metrics-server and devzone services are handled.")
		fmt.Fprintln(out, "  Container, image, volumes and kind clusters: make desinstaller on your machine.")
	}
	if kube.noCluster {
		fmt.Fprintln(out, "Services cluster context: none (no devzone services cluster identified: Kubernetes objects not checked)")
	} else {
		fmt.Fprintf(out, "Services cluster context: %s\n", kube.kubeContext)
	}
	fmt.Fprintln(out, "To remove:")
	fmt.Fprintln(out, " container(s):")
	printList(out, host.containers)
	fmt.Fprintln(out, " image(s):")
	printList(out, host.images)
	fmt.Fprintln(out, " former internal volumes (installs before #291):")
	printList(out, host.dind)
	fmt.Fprintln(out, " volumes:")
	printList(out, host.volumes)
	fmt.Fprintln(out, " metrics-server installed by devzone on:")
	printList(out, host.metrics)
	fmt.Fprintln(out, " namespaces:")
	printList(out, kube.namespaces)
	fmt.Fprintln(out, " Argo CD Applications:")
	printList(out, kube.applications)
	fmt.Fprintln(out, " temporary accounts:")
	printList(out, kube.tempAccounts)
	fmt.Fprintln(out, " kind clusters of the instance on the host engine:")
	printList(out, host.kindClusters)
	fmt.Fprintf(out, " containers labeled devzone.instance=%s:\n", instance)
	printList(out, host.labeled)
	if len(host.kept) > 0 {
		fmt.Fprintln(out, "Kept (KEEP=logins):")
		printList(out, host.kept)
	}
	fmt.Fprintf(out, "Kept:\n  workspace/: %s\n", kube.workspaceKept)
	for _, o := range kube.keptObjects {
		fmt.Fprintf(out, "  %s: not attributable to this instance\n", o)
	}
	if !host.inside && len(host.containers) == 0 && len(host.images) == 0 && !host.stateFile {
		fmt.Fprintln(out, "ℹ No container and no image trace: if an older removal left them,")
		fmt.Fprintf(out, "  find them with: %[2]s images 'vsc-%[1]s-*' ; %[2]s volume ls -q -f name=dind-var-lib-docker\n", filepath.Base(root), engineCommand())
	}
}

// printList prints one indented item per line, or "(none)" for an empty list.
func printList(out io.Writer, items []string) {
	if len(items) == 0 {
		fmt.Fprintln(out, "  (none)")
		return
	}
	for _, i := range items {
		fmt.Fprintf(out, "  %s\n", i)
	}
}
