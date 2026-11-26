package workspace

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// argocdStatus writes the installed state, the GitOps repository and the
// Applications of the workstation Argo CD, as argocd_status does in
// manage/scripts/workspace/argocd-workspace.sh. It is read-only and never
// fails: like the shell, a missing namespace is a status line, not an error.
func argocdStatus(r Runner, confPath, modules string, out io.Writer) int {
	if !argocdInstalled(r) {
		fmt.Fprintln(out, "○ argocd not installed: devzone workspace services enable argocd")
		return 0
	}
	port := os.Getenv("ARGOCD_PORT")
	if port == "" {
		port = "8443"
	}
	if argocdWanted(modules) {
		fmt.Fprintf(out, "✔ argocd installed: https://localhost:%s (devzone workspace ports), user admin, password in .password\n", port)
	} else {
		fmt.Fprintln(out, "⚠ argocd installed but argocd=off in .devzone.modules: devzone workspace services enable argocd, or disable to remove it")
	}
	repo := confValue(confPath, "argocd", "repo")
	if repo != "" && repo != "none" {
		fmt.Fprintf(out, "  GitOps repository: %s (apps/, root Application devzone)\n", repo)
	} else {
		fmt.Fprintln(out, "  no GitOps repository: Applications applied directly (devzone workspace argocd init)")
	}
	args := append(contextFlag(r), "-n", "devzone-argocd", "get", "applications.argoproj.io",
		"-o", `custom-columns=APPLICATION:.metadata.name,KIND:.metadata.labels.devzone\.io/kind,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.spec.source.targetRevision`)
	var list strings.Builder
	_, _ = r.Kubectl(args, nil, &list, io.Discard)
	text := strings.TrimSuffix(list.String(), "\n")
	if text != "" {
		for _, line := range strings.Split(text, "\n") {
			fmt.Fprintln(out, "  "+line)
		}
	}
	return 0
}

// ArgoCDStatus is argocdStatus with the default configuration file of the
// workstation devzone folder, used by the command router.
func ArgoCDStatus(r Runner, modules string, out io.Writer) int {
	return argocdStatus(r, ".argocd.conf", modules, out)
}
