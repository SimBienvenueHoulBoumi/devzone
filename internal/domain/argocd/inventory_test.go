package argocd

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// directInstallMarkers are the textual traces of a chart installation that
// does not go through an Application: a helm install/upgrade or a manifest
// applied with kubectl. The guard does not run any of them.
var directInstallMarkers = []string{
	`"upgrade", "--install"`,
	`"install", "--`,
	`helm upgrade --install`,
	`kubectl apply -f -`,
	`"apply", "-f", "-"`,
}

// allowedDirectInstalls lists every installation path that may still install
// directly, with the reason it is allowed. Argo CD itself and what must exist
// before it are the only exceptions; every other path must reach the shared
// rule, which creates an Application or fails. The inventory is:
//   - argocd module (install.go, install_ns.go): Argo CD itself and its
//     namespace, account and network policy, exception before Argo CD exists;
//   - GitOps bootstrap (gitops_root.go, gitops.sh, apps.sh, services.sh):
//     repository secret, root Application and secrets held apart from Git;
//   - kube-account.sh and isolation.sh: administrator account and isolation;
//   - platform/helm/chart.go: helm implementation, used only by the rule's
//     disabled branch;
//   - gitlab/chart.go and secrets.go: chart dependency and kept secrets;
//   - workspace scripts: the workstation installs the pod and Argo CD;
//   - services-workspace.sh: secrets of the services, not charts.
var allowedDirectInstalls = map[string]string{
	".devcontainer/argocd/apps.sh":                   "repository secrets and Applications of projects added by hand",
	".devcontainer/argocd/gitops.sh":                 "GitOps repository secret and root Application",
	".devcontainer/argocd/services.sh":               "service namespaces and secrets, kept out of Git",
	".devcontainer/isolation.sh":                     "isolation policy of namespaces",
	".devcontainer/kube-account.sh":                  "administrator account and role binding",
	"internal/domain/argocd/install.go":              "Argo CD itself, the only exception",
	"internal/domain/argocd/install_ns.go":           "namespace and account needed before Argo CD",
	"internal/domain/argocd/gitops_root.go":          "repository secret and root Application",
	"internal/domain/argocd/dependency.go":           "external dependency Application, applied directly",
	"internal/command/workspace_deploy_apply.go":     "workspace Application applied directly",
	"internal/domain/argocd/apps_apply.go":           "repository secret and Application when no GitOps repository",
	"internal/domain/argocd/services_reconcile.go":   "service namespace and secret, kept with the data",
	"internal/domain/gitlab/account.go":              "namespace and administrator account",
	"internal/domain/gitlab/argocd.go":               "Application direct apply when no GitOps repository",
	"internal/domain/gitlab/chart.go":                "chart dependency, when Argo CD is off",
	"internal/domain/gitlab/secrets.go":              "secret kept in the workspace",
	"internal/domain/gitlab/seed_api.go":             "secret of the GitLab seed",
	"internal/domain/postgres/install.go":            "namespace of PostgreSQL, when Argo CD is off",
	"internal/platform/helm/chart.go":                "helm implementation of the disabled branch",
	"internal/platform/kube/namespace.go":            "namespace helper of the modules",
	"internal/workspace/helm_deploy.go":              "workspace chart by helm, only when Argo CD is neither wanted nor installed",
	"internal/workspace/services_command.go":         "temporary administrator account of the services installer, removed at the end",
	"manage/scripts/workspace/argocd-workspace.sh":   "Argo CD of the workstation, installed before it exists",
	"manage/scripts/workspace/services-workspace.sh": "secrets of the services, kept out of Git",
	"manage/workspace.sh":                            "workspace pod, when Argo CD is off",
}

// TestNoNewDirectInstallPath fails when a source file gains a direct helm or
// kubectl installation outside the declared inventory. Why: with Argo CD on,
// every service and application must become an Application, and a new direct
// path would silently leave data under two managers.
func TestNoNewDirectInstallPath(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	found := map[string]bool{}
	for _, dir := range []string{"internal", "manage", ".devcontainer"} {
		err := filepath.WalkDir(filepath.Join(root, dir), func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !sourceFile(entry.Name()) {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			text := string(data)
			for _, marker := range directInstallMarkers {
				if strings.Contains(text, marker) {
					rel, _ := filepath.Rel(root, path)
					found[filepath.ToSlash(rel)] = true
					break
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	var unknown []string
	for path := range found {
		if _, ok := allowedDirectInstalls[path]; !ok {
			unknown = append(unknown, path)
		}
	}
	sort.Strings(unknown)
	if len(unknown) > 0 {
		t.Fatalf("new direct installation path(s), add them to the rule or to the inventory: %v", unknown)
	}
}

// sourceFile reports whether name is a source file covered by the guard:
// tests are excluded because they only declare expected calls.
func sourceFile(name string) bool {
	if strings.HasSuffix(name, "_test.go") {
		return false
	}
	return strings.HasSuffix(name, ".go") || strings.HasSuffix(name, ".sh")
}
