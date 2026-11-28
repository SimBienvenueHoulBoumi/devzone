package clustermenu

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// localContexts are the names of contexts that are always local (never offered
// as a remote cluster); desktop-, kind- and k3d- prefixes are local too. The
// services context name comes from the shared helper, never from a copy.
var localContexts = map[string]bool{
	"docker-desktop": true, "minikube": true, exec.DevzoneContextName: true,
	"rancher-desktop": true, "orbstack": true, "colima": true,
}

// localPrefixes are the prefixes of local context names
var localPrefixes = []string{"desktop-", "kind-", "k3d-"}

// remote asks for a remote context, then its name typed back. It returns true
// once the context is the current one of kubectl.
func (m *Menu) remote() bool {
	list := m.remoteContexts()
	if len(list) == 0 {
		fmt.Fprintln(m.Err, "✖ no remote context in your kubeconfig: add one with the command of your provider (aws, gcloud, az), then run the same command again")
		return false
	}
	fmt.Fprintln(m.Out, "Remote contexts of your kubeconfig:")
	for i, c := range list {
		fmt.Fprintf(m.Out, "  %d) %s (remote)\n", i+1, c)
	}
	answer := m.ask("Number of the cluster (empty to cancel): ")
	if !isDigits(answer) {
		fmt.Fprintln(m.Err, "✖ cancelled")
		return false
	}
	n, err := strconv.Atoi(answer)
	if err != nil || n < 1 || n > len(list) {
		fmt.Fprintf(m.Err, "✖ no such cluster: %s\n", answer)
		return false
	}
	ctx := list[n-1]
	fmt.Fprintf(m.Out, "remote cluster: %s. devzone will install a pod, a volume and the namespace "+config.NamespaceWorkspace+" in it: it needs enough rights and may cost.\n", ctx)
	if m.ask("Type its name to confirm: ") != ctx {
		fmt.Fprintln(m.Err, "✖ name not typed back: nothing done")
		return false
	}
	if _, ok := m.run("kubectl", "config", "use-context", ctx); !ok {
		fmt.Fprintf(m.Err, "✖ cannot select the context %s\n", ctx)
		return false
	}
	fmt.Fprintf(m.Out, "✔ current kubectl context: %s\n", ctx)
	return true
}

// remoteContexts lists the contexts of the kubeconfig that are not local, in
// the order of kubectl. A kubectl failure gives an empty list, as in the shell.
func (m *Menu) remoteContexts() []string {
	res, _ := m.Runner.Run(m.Ctx, "kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Opts{})
	var out []string
	for _, ctx := range strings.Split(string(res.Stdout), "\n") {
		if ctx == "" {
			continue
		}
		if !m.isLocal(ctx) {
			out = append(out, ctx)
		}
	}
	return out
}

// isLocal tells whether a context is a local cluster: by its name, or because
// its server address is the loopback one. A context whose name matches the
// resolved services context (from DEVZONE_CONTEXT or .argocd.conf) is also
// considered local so it is not offered as a remote cluster.
func (m *Menu) isLocal(ctx string) bool {
	if localContexts[ctx] {
		return true
	}
	if ctx == exec.ContextName() {
		return true
	}
	for _, p := range localPrefixes {
		if strings.HasPrefix(ctx, p) {
			return true
		}
	}
	server := m.server(ctx)
	return strings.Contains(server, "//127.0.0.1") ||
		strings.Contains(server, "//localhost") ||
		strings.Contains(server, "//[::1]")
}

// server returns the API server address of a context ("" when unknown)
func (m *Menu) server(ctx string) string {
	res, _ := m.Runner.Run(m.Ctx, "kubectl", []string{"config", "view", "--minify", "--context", ctx, "-o", "jsonpath={.clusters[0].cluster.server}"}, exec.Opts{})
	return strings.TrimRight(string(res.Stdout), "\n")
}

// isDigits reports whether s is a non-empty run of ASCII digits
func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
