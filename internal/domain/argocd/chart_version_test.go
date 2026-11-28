package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/checks"
)

// chartDependencyVersion reads the pinned version of one dependency in a
// Chart.yaml without a YAML library: each dependency has its own name and
// version lines under the dependencies key.
func chartDependencyVersion(data, dependency string) string {
	lines := strings.Split(data, "\n")
	for i, line := range lines {
		if strings.TrimSpace(line) != "- name: "+dependency {
			continue
		}
		for _, next := range lines[i+1:] {
			trimmed := strings.TrimSpace(next)
			if strings.HasPrefix(trimmed, "- name:") {
				break
			}
			if value, ok := strings.CutPrefix(trimmed, "version:"); ok {
				return strings.Trim(strings.TrimSpace(value), `"'`)
			}
		}
	}
	return ""
}

// TestArgoCDChartVersionIsInSync keeps defaultVersion of the code equal to the
// argo-cd dependency pinned in the chart, finding the repository from any
// working directory like the architecture checks do.
func TestArgoCDChartVersionIsInSync(t *testing.T) {
	root, err := checks.RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "charts", "devzone-argocd", "Chart.yaml")
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	version := chartDependencyVersion(string(data), "argo-cd")
	if version == "" {
		t.Fatalf("no argo-cd dependency version in %s", file)
	}
	if version != defaultVersion {
		t.Fatalf("argo-cd dependency is %s in %s but defaultVersion is %s: update both together", version, file, defaultVersion)
	}
}
