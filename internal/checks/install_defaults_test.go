package checks

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// forbiddenInstallDefaults are the installation values that must live only in
// internal/framework/config, never repeated in Go production code.
var forbiddenInstallDefaults = []string{
	"gitlab.localhost:8929",
	"gitlab.localhost:2224",
	"ghcr.io/simbienvenuehoulboumi/devzone-workspace",
}

// installDefaultExceptions are the definition files and the few remaining
// surfaces of this lot; each value states why its literal is still allowed.
var installDefaultExceptions = map[string]string{
	"internal/framework/config/image.go":  "image definition",
	"internal/framework/config/gitlab.go": "GitLab definition",
	"internal/domain/gitlab/gitlab.go":    "module default outside this lot",
	"internal/domain/gitlab/install.go":   "installation text outside this lot",
	"internal/domain/gitlab/status.go":    "status text outside this lot",
	"internal/podcmd/platform.go":         "platform default outside this lot",
	"internal/passwords/collect.go":       "credential entries outside this lot",
}

// TestNoHardcodedInstallDefaults fails when a GitLab address or the workspace
// image is written again outside the shared definitions, using the repository
// root so the check works from any folder.
func TestNoHardcodedInstallDefaults(t *testing.T) {
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
		if _, ok := installDefaultExceptions[rel]; ok {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for i, line := range strings.Split(string(data), "\n") {
			for _, literal := range forbiddenInstallDefaults {
				if strings.Contains(line, literal) {
					faults = append(faults, fmt.Sprintf("%s:%d: %s", rel, i+1, literal))
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(faults) > 0 {
		t.Fatalf("hardcoded installation defaults found (use internal/framework/config):\n%s", strings.Join(faults, "\n"))
	}
}
