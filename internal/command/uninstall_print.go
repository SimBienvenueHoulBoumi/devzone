package command

import (
	"fmt"
	"io"
)

func printUninstallPlan(out io.Writer, plan uninstallPlan) {
	fmt.Fprintf(out, "Services cluster context: %s\n", plan.kubeContext)
	fmt.Fprintln(out, "To remove:")
	fmt.Fprintln(out, " namespaces:")
	printList(out, plan.namespaces)
	fmt.Fprintln(out, " Argo CD Applications:")
	printList(out, plan.applications)
	fmt.Fprintln(out, " temporary accounts:")
	printList(out, plan.tempAccounts)
	fmt.Fprintln(out, " .devzone.* files:")
	printList(out, plan.devzoneFiles)
	fmt.Fprintf(out, "Kept:\n  workspace/: %s\n", plan.workspaceKept)
	for _, o := range plan.keptObjects {
		fmt.Fprintf(out, "  %s: not attributable to this instance\n", o)
	}
}

func printList(out io.Writer, items []string) {
	if len(items) == 0 {
		fmt.Fprintln(out, "  (none)")
		return
	}
	for _, i := range items {
		fmt.Fprintf(out, "  %s\n", i)
	}
}

// applyUninstallPlan deletes the planned objects. Failures are reported but do
// not stop cleanup of other objects; the .devzone.* files are removed only
// when every cluster deletion succeeded, so a retry can still finish the job.
