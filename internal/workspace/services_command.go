package workspace

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// servicesAdminSA and the default token duration are the constants of
// workspace services (Go), shared with the pod installer.
const (
	servicesAdminSA = "devzone-services-admin"
	servicesScript  = "/usr/local/share/devzone/.devcontainer/services-admin.sh"
)

// servicesNamespace returns the namespace of a service, as in the shell.
func servicesNamespace(service string) string {
	switch service {
	case "gitlab":
		return "devzone-gitlab"
	case "postgres":
		return "devzone-postgres"
	case "mysql":
		return "devzone-mysql"
	case "argocd":
		return "devzone-argocd"
	}
	return ""
}

// ServicesKnown tells whether a service can be enabled or disabled.
func ServicesKnown(service string) bool {
	return servicesNamespace(service) != ""
}

// ServicesUsage is the one-line usage of the services command.
const ServicesUsage = "devzone workspace services enable|disable <gitlab|postgres|mysql|argocd> [options] | seed gitlab | status"

// ServicesEnv runs the non-Argo CD forms of "devzone workspace services": the
// workstation creates a temporary administrator and runs the installer in the
// pod with its token on stdin. The Argo CD forms are left to the caller, which
// delegates them to the shell until the GitOps libraries are ported.
type ServicesEnv struct {
	Runner  Runner
	Modules string
	Out     io.Writer
	ErrOut  io.Writer
	Script  string
	Token   string
}

// Run dispatches enable, disable and seed, as services in workspace services (Go).
func (e ServicesEnv) Run(args []string) int {
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "enable", "disable":
		if len(args) < 2 {
			fmt.Fprintf(e.ErrOut, "✖ unknown service: none (%s)\n", ServicesUsage)
			return 1
		}
		return e.run(sub, args[1], args[2:])
	case "seed":
		if len(args) < 2 || args[1] != "gitlab" {
			fmt.Fprintf(e.ErrOut, "✖ seed: only gitlab (%s)\n", ServicesUsage)
			return 1
		}
		return e.run("seed", "gitlab", nil)
	default:
		fmt.Fprintf(e.ErrOut, "✖ unknown subcommand: %s (%s)\n", sub, ServicesUsage)
		return 1
	}
}

// run creates the administrator, obtains a one-hour token, runs the installer
// and removes the administrator whatever the outcome. The token is only sent
// on the standard input of kubectl exec, never printed nor recorded.
func (e ServicesEnv) run(action, service string, options []string) int {
	if !ServicesKnown(service) {
		fmt.Fprintf(e.ErrOut, "✖ unknown service: %s (%s)\n", service, ServicesUsage)
		return 1
	}
	flag := contextFlag(e.Runner)
	phase := strings.TrimSpace(kubectlText(e.Runner, append(flag, "get", "pod", pod, "--namespace", namespace,
		"-o", `jsonpath={.status.phase}`)))
	if phase != "Running" {
		fmt.Fprintf(e.ErrOut, "✖ workspace pod %s not running: devzone workspace start\n", pod)
		return 1
	}
	fmt.Fprintf(e.Out, "▶ temporary administrator %s (removed at the end)…\n", servicesAdminSA)
	manifest := adminManifest()
	if status, err := e.Runner.Kubectl(append(flag, "apply", "-f", "-"), strings.NewReader(manifest), io.Discard, io.Discard); err != nil || status != 0 {
		fmt.Fprintln(e.ErrOut, "✖ cannot create the temporary administrator: cluster-admin rights needed on the workstation")
		e.removeAdmin(flag)
		return 1
	}
	token := e.Token
	if token == "" {
		var out strings.Builder
		duration := os.Getenv("DEVZONE_SERVICES_TOKEN_DURATION")
		if duration == "" {
			duration = "1h"
		}
		status, err := e.Runner.Kubectl(append(flag, "create", "token", servicesAdminSA,
			"--namespace", namespace, "--duration", duration), nil, &out, io.Discard)
		if err != nil || status != 0 || strings.TrimSpace(out.String()) == "" {
			fmt.Fprintln(e.ErrOut, "✖ cannot get a token of the temporary administrator (kubectl 1.24 or more)")
			e.removeAdmin(flag)
			return 1
		}
		token = strings.TrimSpace(out.String())
	}
	fmt.Fprintf(e.Out, "▶ %s %s in the pod %s…\n", action, service, pod)
	args := append(flag, "exec", "-i", pod, "--namespace", namespace, "-c", container, "--",
		"bash", e.script(), action, service)
	args = append(args, options...)
	status, err := e.Runner.Kubectl(args, strings.NewReader(token+"\n"), e.Out, e.ErrOut)
	e.removeAdmin(flag)
	if err != nil || status != 0 {
		fmt.Fprintf(e.ErrOut, "✖ %s %s failed (code %d); in the pod: devzone status\n", action, service, status)
		if err != nil {
			return 1
		}
		return status
	}
	if value, ok := map[string]string{"enable": "on", "disable": "off"}[action]; ok {
		if err := noteModulesKey(e.Modules, service, value); err != nil {
			fmt.Fprintf(e.ErrOut, "✖ cannot write %s: %v\n", e.Modules, err)
			return 1
		}
	}
	fmt.Fprintf(e.Out, "✔ %s %s done; in the pod: devzone status; local access: devzone workspace ports\n", action, service)
	return 0
}

// script returns the installer path, with the test override.
func (e ServicesEnv) script() string {
	if e.Script != "" {
		return e.Script
	}
	if path := os.Getenv("DEVZONE_SERVICES_ADMIN_SCRIPT"); path != "" {
		return path
	}
	return servicesScript
}

// ArgoCDHoldsCharts tells whether Argo CD drives the charts: it is installed,
// wanted in the modules file, and a Git revision is available. It is the
// argocd_holds_charts of argocd-services.sh, used by services to leave the
// Argo CD path to the shell while the GitOps libraries are not ported.
func ArgoCDHoldsCharts(r Runner, modules string) bool {
	return argocdActive(r, modules) && argocdRevision(packageRoot()) != ""
}

// removeAdmin deletes the temporary ServiceAccount and its binding, ignoring
// the result: the cleanup must never hide the result of the installer.
func (e ServicesEnv) removeAdmin(flag []string) {
	_, _ = e.Runner.Kubectl(append(flag, "delete", "clusterrolebinding", servicesAdminSA,
		"--ignore-not-found"), nil, io.Discard, io.Discard)
	_, _ = e.Runner.Kubectl(append(flag, "delete", "serviceaccount", servicesAdminSA,
		"--namespace", namespace, "--ignore-not-found"), nil, io.Discard, io.Discard)
}

// adminManifest is the ServiceAccount and its cluster-admin binding, as in
// services_admin_create of workspace services (Go).
func adminManifest() string {
	return "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: " + servicesAdminSA +
		"\n  namespace: " + namespace + "\n---\napiVersion: rbac.authorization.k8s.io/v1\n" +
		"kind: ClusterRoleBinding\nmetadata:\n  name: " + servicesAdminSA +
		"\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: cluster-admin\n" +
		"subjects:\n  - kind: ServiceAccount\n    name: " + servicesAdminSA + "\n    namespace: " + namespace + "\n"
}
