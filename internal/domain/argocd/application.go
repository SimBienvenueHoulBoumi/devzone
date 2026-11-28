package argocd

import (
	"io"

	rule "github.com/SimBienvenueHoulBoumi/devzone/internal/platform/argocd"
)

// RenderApplication writes an Argo CD Application manifest to w. It is the
// shared renderer of the shell generator and of every module of devzone.
func RenderApplication(w io.Writer, name, kind, namespace, repo, revision, path string, params []string, valuesRepo string) error {
	return rule.RenderApplication(w, name, kind, namespace, repo, revision, path, params, valuesRepo)
}

// RenderChartApplication writes an Application whose source is an external
// Helm chart, for dependencies such as metrics-server.
func RenderChartApplication(w io.Writer, name, namespace, repo, chart, version string, params []string) error {
	return rule.RenderChartApplication(w, name, namespace, repo, chart, version, params)
}
