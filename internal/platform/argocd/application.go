package argocd

import (
	"fmt"
	"io"
	"strings"
)

const (
	workspaceAppName = "devzone-workspace"
	// WorkspaceValuesPath is the values file of the workspace chart in a GitOps
	// repository, shared by the Application renderer and by the commands that
	// create, validate and report it.
	WorkspaceValuesPath = "values/devzone-workspace.yaml"
)

// RenderApplication writes an Argo CD Application manifest to w. It mirrors
// the former application.sh shell generator byte for byte in its meaningful output:
// automated sync with prune and selfHeal, the destination namespace created,
// resources deleted with the Application, and the Application in devzone-argocd.
// The workspace with a GitOps repository uses two sources: its chart reads the
// values file of that repository, while helm parameters stay authoritative.
func RenderApplication(w io.Writer, name, kind, namespace, repo, revision, path string, params []string, valuesRepo string) error {
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
	fmt.Fprintf(&b, "apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: %s\n  namespace: devzone-argocd\n  labels:\n    app.kubernetes.io/managed-by: devzone\n    devzone.io/kind: %s\n  finalizers:\n    - resources-finalizer.argocd.argoproj.io\nspec:\n  project: default\n", name, kind)
	twoSources := name == workspaceAppName && valuesRepo != "" && valuesRepo != "none"
	if twoSources {
		fmt.Fprintf(&b, "  sources:\n    - repoURL: %s\n      targetRevision: %s\n      path: %s\n", repo, revision, path)
		writeHelm(&b, params, "      ", true)
		fmt.Fprintf(&b, "    - repoURL: %s\n      targetRevision: HEAD\n      ref: values\n", valuesRepo)
	} else {
		fmt.Fprintf(&b, "  source:\n    repoURL: %s\n    targetRevision: %s\n    path: %s\n", repo, revision, path)
		writeHelm(&b, params, "    ", false)
	}
	fmt.Fprintf(&b, "  destination:\n    server: https://kubernetes.default.svc\n    namespace: %s\n  syncPolicy:\n    automated:\n      prune: true\n      selfHeal: true\n    syncOptions:\n      - CreateNamespace=true\n", namespace)
	_, err := io.WriteString(w, b.String())
	return err
}

// writeHelm writes the Helm block of one Application source. The multi-source
// workspace adds the shared values file; parameters are written last so that
// Argo CD applies them over the values file.
func writeHelm(b *strings.Builder, params []string, indent string, values bool) {
	if len(params) == 0 && !values {
		return
	}
	b.WriteString(indent + "helm:\n")
	if values {
		b.WriteString(indent + "  valueFiles:\n")
		fmt.Fprintf(b, indent+"    - $values/%s\n", WorkspaceValuesPath)
		b.WriteString(indent + "  ignoreMissingValueFiles: true\n")
	}
	if len(params) == 0 {
		return
	}
	b.WriteString(indent + "  parameters:\n")
	for _, kv := range params {
		k, v, _ := strings.Cut(kv, "=")
		fmt.Fprintf(b, indent+"    - name: %s\n"+indent+"      value: \"%s\"\n", k, v)
	}
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
// used by the former shell generator: lowercase letters, digits and dashes, no leading dash.
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
