package command

import (
	"fmt"
	"io"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
)

// printRemains lists what the uninstall leaves on purpose, after the removal: the
// workspace, the foreign metrics-servers, the shared images and caches, the
// GitOps repository and this folder. It is printed on every run that got here.
func printRemains(out io.Writer, root string, host hostPlan) {
	fmt.Fprintln(out)
	fmt.Fprintln(out, "Not touched (remove yourself if you want):")
	fmt.Fprintln(out, "  workspace/: your projects")
	for _, c := range host.foreign {
		fmt.Fprintf(out, "  metrics-server on %s: not installed by devzone (kubectl --context %s -n kube-system delete deployment metrics-server)\n", c, c)
	}
	if host.kubectlMissing {
		fmt.Fprintln(out, "  metrics-server: kubectl not on host, host clusters not checked")
	}
	fmt.Fprintln(out, "  base image mcr.microsoft.com/devcontainers/base (shared): docker rmi mcr.microsoft.com/devcontainers/base:ubuntu-24.04")
	fmt.Fprintln(out, "  devcontainer CLI npx cache: ~/.npm/_npx")
	fmt.Fprintln(out, "  \"GitHub CLI\" authorization on your account: GitHub → Settings → Applications")
	if repo := (argocd.Conf{Path: filepath.Join(root, ".argocd.conf")}).Get("argocd", "repo"); repo != "" && repo != "none" {
		fmt.Fprintf(out, "  GitOps repository not removed: %s (delete it yourself if you want to)\n", repo)
	}
	fmt.Fprintf(out, "  this folder: %s\n", root)
}
