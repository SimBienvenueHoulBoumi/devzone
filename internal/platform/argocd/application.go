package argocd

import (
	"fmt"
	"io"
	"strings"
)

// RenderApplication writes an Argo CD Application manifest to w. It mirrors
// .devcontainer/argocd/application.sh byte for byte in its meaningful output:
// automated sync with prune and selfHeal, the destination namespace created,
// resources deleted with the Application, and the Application in devzone-argocd.
func RenderApplication(w io.Writer, name, kind, namespace, repo, revision, path string, params []string) error {
	switch kind {
	case "workspace", "service", "project", "root":
	default:
		return fmt.Errorf("application.sh: unknown kind: %s (workspace, service, project, root)", kind)
	}
	if !validAppName(name) {
		return fmt.Errorf("application.sh: invalid name: %s (lowercase letters, digits, dashes)", displayName(name))
	}
	if namespace == "" || repo == "" || revision == "" || path == "" {
		return fmt.Errorf("usage: application.sh <name> <kind> <destination namespace> <repo url> <revision> <path> [key=value ...]")
	}
	for _, kv := range params {
		if !strings.Contains(kv, "=") {
			return fmt.Errorf("application.sh: Helm parameter without value: %s", kv)
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: %s\n  namespace: devzone-argocd\n  labels:\n    app.kubernetes.io/managed-by: devzone\n    devzone.io/kind: %s\n  finalizers:\n    - resources-finalizer.argocd.argoproj.io\nspec:\n  project: default\n  source:\n    repoURL: %s\n    targetRevision: %s\n    path: %s\n", name, kind, repo, revision, path)
	if len(params) > 0 {
		b.WriteString("    helm:\n      parameters:\n")
		for _, kv := range params {
			k, v, _ := strings.Cut(kv, "=")
			fmt.Fprintf(&b, "        - name: %s\n          value: \"%s\"\n", k, v)
		}
	}
	fmt.Fprintf(&b, "  destination:\n    server: https://kubernetes.default.svc\n    namespace: %s\n  syncPolicy:\n    automated:\n      prune: true\n      selfHeal: true\n    syncOptions:\n      - CreateNamespace=true\n", namespace)
	_, err := io.WriteString(w, b.String())
	return err
}

// RenderChartApplication writes an Application whose source is an external
// Helm chart, for dependencies such as metrics-server. It reuses the sync
// policy of RenderApplication; only the source differs, so no chart of devzone
// has to change for a dependency to be held by Argo CD.
func RenderChartApplication(w io.Writer, name, namespace, repo, chart, version string, params []string) error {
	if !validAppName(name) || namespace == "" || repo == "" || chart == "" || version == "" {
		return fmt.Errorf("chart application: name, namespace, repo, chart and version are required")
	}
	var b strings.Builder
	fmt.Fprintf(&b, "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: %s\n  namespace: devzone-argocd\n  labels:\n    app.kubernetes.io/managed-by: devzone\n    devzone.io/kind: dependency\n  finalizers:\n    - resources-finalizer.argocd.argoproj.io\nspec:\n  project: default\n  source:\n    repoURL: %s\n    chart: %s\n    targetRevision: %s\n", name, repo, chart, version)
	if len(params) > 0 {
		b.WriteString("    helm:\n      parameters:\n")
		for _, kv := range params {
			k, v, _ := strings.Cut(kv, "=")
			fmt.Fprintf(&b, "        - name: %s\n          value: \"%s\"\n", k, v)
		}
	}
	fmt.Fprintf(&b, "  destination:\n    server: https://kubernetes.default.svc\n    namespace: %s\n  syncPolicy:\n    automated:\n      prune: true\n      selfHeal: true\n", namespace)
	_, err := io.WriteString(w, b.String())
	return err
}

// validAppName reports whether name is a valid Argo CD Application name fragment
// used by the shell generator: lowercase letters, digits and dashes, no leading dash.
func validAppName(name string) bool {
	if name == "" || strings.HasPrefix(name, "-") {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			continue
		}
		return false
	}
	return true
}

// displayName returns (none) for an empty name, matching the shell error.
func displayName(name string) string {
	if name == "" {
		return "(none)"
	}
	return name
}
