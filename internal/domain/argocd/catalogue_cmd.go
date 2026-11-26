package argocd

import (
	"fmt"
	"os"
)

// catalogueActiveCmd reports whether Argo CD can hold an app (exit 0/1).
func (m *module) catalogueActiveCmd(args []string) int {
	if len(args) != 1 {
		return 2
	}
	if m.catalogueArgocdActive(args[0]) {
		return 0
	}
	return 1
}

// catalogueApplicationExistsCmd reports whether an Application exists (exit 0/1).
func (m *module) catalogueApplicationExistsCmd(args []string) int {
	if len(args) != 1 {
		return 2
	}
	if m.catalogueArgocdApplicationExists(args[0]) {
		return 0
	}
	return 1
}

// catalogueDeleteCmd deletes devzone-<app> Application (no-op when absent).
func (m *module) catalogueDeleteCmd(args []string) int {
	if len(args) != 1 {
		return 2
	}
	app := args[0]
	if !m.catalogueArgocdApplicationExists(app) {
		return 0
	}
	return m.gitopsDeleteApplication("devzone-"+app, "cascade")
}

// catalogueApplyCmd applies the service Application for a catalog app.
func (m *module) catalogueApplyCmd(args []string) int {
	if len(args) < 6 {
		fmt.Fprintln(m.errOut, "usage: devzone argocd catalogue-apply <app> <ns> <image> <port> <memory> <size> [extra...]")
		return 2
	}
	app, ns, image, port, memory, size := args[0], args[1], args[2], args[3], args[4], args[5]
	if rc := m.chartRequire(app); rc != 0 {
		return rc
	}
	params := []string{"image=" + image, "port=" + port, "memory=" + memory, "size=" + size}
	for _, e := range args[6:] {
		if e != "" {
			params = append(params, e)
		}
	}
	repoURL := os.Getenv("DEVZONE_REPO_URL")
	if repoURL == "" {
		repoURL = "https://github.com/SimBienvenueHoulBoumi/devzone.git"
	}
	if code := m.gitopsApplyApplication("devzone-"+app, "service", ns, repoURL, m.argocdRevision(), "charts/devzone-"+app, params...); code != 0 {
		return code
	}
	_, _ = m.kubectl("-n", "devzone-argocd", "annotate", "application.argoproj.io", "devzone-"+app, "argocd.argoproj.io/refresh=normal", "--overwrite")
	return 0
}

// catalogueStatus prints argocd revision; helper for shell callers.
func (m *module) catalogueRevisionCmd(args []string) int {
	fmt.Fprintln(m.out, m.argocdRevision())
	return 0
}
