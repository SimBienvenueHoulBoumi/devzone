package podcmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// printModules writes one status line per module, in the order of the former
// shell summary, including the Argo CD hold line of each module.
func printModules(ctx *cli.Context, d jsonDeps) {
	inPod := os.Getenv("DEVZONE_WORKSPACE") == "kubernetes"
	for _, name := range moduleNames {
		active := d.st.Get(name) == "on"
		switch {
		case inPod && serviceModule(name):
			printPodModuleLine(ctx, d, name, active)
		case active && failureMarker(d, name) != "":
			fmt.Fprintf(ctx.Out, "  ✖ module %-10s failed: incomplete install (%s): devzone apply\n", name, failureMarker(d, name))
		case active && isStatusModule(name):
			out, code, err := d.run(podCommand(d), name, "status")
			value := ""
			if err == nil && code == 0 {
				value = trimNewlines(out)
			}
			fmt.Fprintf(ctx.Out, "  ✔ module %-10s %s\n", name, value)
		case active:
			fmt.Fprintf(ctx.Out, "  ✔ module %-10s active: %s\n", name, moduleDescription(name))
		default:
			fmt.Fprintf(ctx.Out, "  ○ module %-10s optional, %s: devzone enable %s\n", name, moduleDescription(name), name)
		}
		if heldByArgoCD(d, name) {
			fmt.Fprintf(ctx.Out, "                    tenu par Argo CD : Application devzone-%s\n", name)
		}
	}
}

// failureMarker returns the reason stored by a failed installation, or an empty
// string when no marker file is present for this module.
func failureMarker(d jsonDeps, name string) string {
	data, err := os.ReadFile(d.st.Path() + "-failed-" + name)
	if err != nil {
		return ""
	}
	return trimNewlines(string(data))
}

// isStatusModule reports whether a module has a detailed status command in the
// pod CLI; the other active modules are described from their state line.
func isStatusModule(name string) bool {
	switch name {
	case "gitlab", "postgres", "argocd", "mysql":
		return true
	}
	return false
}

// printPodModuleLine reports a service of the Kubernetes workspace pod from
// its cluster DNS name, never from an installer on the pod itself.
func printPodModuleLine(ctx *cli.Context, d jsonDeps, name string, active bool) {
	dns := serviceDNS(name)
	_, code, err := d.run("getent", "hosts", dns)
	switch {
	case err == nil && code == 0:
		fmt.Fprintf(ctx.Out, "  ✔ module %-10s active: %s (%s)\n", name, moduleDescription(name), dns)
	case active:
		fmt.Fprintf(ctx.Out, "  ⚠ module %-10s not in the cluster: on the workstation, devzone workspace services enable %s\n", name, name)
	default:
		fmt.Fprintf(ctx.Out, "  ○ module %-10s optional, %s: on the workstation, devzone workspace services enable %s\n", name, moduleDescription(name), name)
	}
}

// podCommand returns the path of the pod launcher so Go can ask it for commands
// still outside this binary, falling back to its PATH name when not installed.
func podCommand(d jsonDeps) string {
	if d.code != "" {
		return filepath.Join(d.code, "devzone")
	}
	return "devzone"
}
