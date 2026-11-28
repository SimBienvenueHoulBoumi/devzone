package checks

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// namespaceNames are the fixed namespace names of the installation; the test
// looks for each of them as the whole value of a Go string literal.
var namespaceNames = []string{
	config.NamespaceArgoCD,
	config.NamespaceGitLab,
	config.NamespaceWorkspace,
	config.NamespacePostgres,
}

// namespaceLiteralAllowance lists the non-namespace uses of those same strings:
// a line holding one of the needles is not a namespace write. Each entry states
// why the literal is allowed, so a new namespace write never hides behind it.
var namespaceLiteralAllowance = []struct {
	reason  string
	names   []string
	needles []string
}{
	{
		reason:  "chart name or chart folder",
		names:   []string{config.NamespaceWorkspace, config.NamespaceGitLab},
		needles: []string{"Chart:", `"charts"`},
	},
	{
		reason: "Application name (workspace or GitLab)",
		names:  []string{config.NamespaceWorkspace, config.NamespaceGitLab},
		needles: []string{
			"RenderApplication(", `"application.argoproj.io", "`,
			"gitopsWriteApp(", `"argocd.argoproj.io/refresh=normal"`,
			"workspaceAppName", "argocdApp", "targetRevision", "releaseName",
			`"devzone-gitlab", "--ignore-not-found"`,
		},
	},
	{
		reason:  "Helm release name",
		names:   []string{config.NamespaceWorkspace},
		needles: []string{"releaseName", `"helm", "status"`, `"upgrade"`, `"uninstall"`},
	},
	{
		reason:  "StatefulSet name",
		names:   []string{config.NamespaceWorkspace},
		needles: []string{`"statefulset"`},
	},
	{
		reason:  "preferred debug image base name",
		names:   []string{config.NamespaceWorkspace},
		needles: []string{`"devzone-workspace", "postgres"`},
	},
	{
		reason:  "GitOps repository or GitLab project name",
		names:   []string{config.NamespaceArgoCD},
		needles: []string{"proj =", "gitopsRepoName", `name = "devzone-argocd"`},
	},
}

// namespaceLiteralAllowed reports whether the line is a documented non-namespace
// use of name, and the reason it is allowed.
func namespaceLiteralAllowed(line, name string) (string, bool) {
	for _, allowance := range namespaceLiteralAllowance {
		allowed := false
		for _, allowedName := range allowance.names {
			if name == allowedName {
				allowed = true
				break
			}
		}
		if !allowed {
			continue
		}
		for _, needle := range allowance.needles {
			if strings.Contains(line, needle) {
				return allowance.reason, true
			}
		}
	}
	return "", false
}

// namespaceLiteralSkipped reports whether the file is outside this check: the
// namespace definition, the GitLab end-to-end tests, the AI guard and its
// command are handled by other lots and are not touched here.
func namespaceLiteralSkipped(rel string) bool {
	if rel == "internal/framework/config/namespaces.go" {
		return true
	}
	return strings.HasPrefix(rel, "internal/domain/gitlab/e2e/") ||
		strings.HasPrefix(rel, "internal/domain/ai/guard/") ||
		rel == "internal/podcmd/ai.go"
}

// TestNoHardcodedNamespaces fails when a namespace name is written as the whole
// value of a Go string literal outside its shared definition, using the
// repository root so the check works from any folder.
func TestNoHardcodedNamespaces(t *testing.T) {
	root, err := RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	var faults []string
	err = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".git" || d.Name() == "vendor" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if namespaceLiteralSkipped(rel) {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for i, line := range strings.Split(string(data), "\n") {
			for _, name := range namespaceNames {
				if !strings.Contains(line, `"`+name+`"`) {
					continue
				}
				if _, ok := namespaceLiteralAllowed(line, name); ok {
					continue
				}
				faults = append(faults, fmt.Sprintf("%s:%d: %s", rel, i+1, strings.TrimSpace(line)))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(faults) > 0 {
		t.Fatalf("hardcoded namespace names found (use internal/framework/config):\n%s", strings.Join(faults, "\n"))
	}
}
