package checks

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// contextNamePattern lists the Go shapes that write the services context name
// by hand: the kubectl configuration commands followed by the literal, and the
// comparisons against it. The name itself has one home, the shared helper.
var contextNamePattern = regexp.MustCompile(
	`"--context", *"devzone"|--context devzone|--kube-context` +
		`|use-context.*"devzone"|set-context.*"devzone"|get-contexts.*"devzone"` +
		`|== "devzone"`)

// contextNameExcept are the files this lot leaves alone, where the literal
// "devzone" is a cluster, an instance, an object or the program name rather
// than a write of the services context. context.go holds the single definition
// of the name; rebuild.go reads the host kubeconfig of another lot. The GitLab
// end-to-end tests are skipped by prefix, below.
var contextNameExcept = map[string]bool{
	"internal/checks/patterns.go":               true,
	"internal/command/uninstall_filter.go":      true,
	"internal/command/uninstall_host_engine.go": true,
	"internal/domain/agent/state.go":            true,
	"internal/domain/argocd/apps.go":            true,
	"internal/domain/gitlab/gitlab.go":          true,
	"internal/framework/exec/context.go":        true,
	"internal/framework/state/rebuild.go":       true,
	"internal/platform/kube/cluster.go":         true,
	"internal/podcmd/state_json_cluster.go":     true,
	"internal/podcmd/status_details.go":         true,
}

// checkContextForm fails when the pattern misses the example that writes the
// name by hand, or when it flags the fixed form of that same line, so each
// form of the pattern is proven on a string of its own.
func checkContextForm(t *testing.T, name, broken, fixed string) {
	t.Helper()
	if !contextNamePattern.MatchString(broken) {
		t.Errorf("%s: pattern misses %q", name, broken)
	}
	if contextNamePattern.MatchString(fixed) {
		t.Errorf("%s: pattern flags the fixed form %q", name, fixed)
	}
}

// TestContextNamePatternUseContext: a use-context naming the literal is caught.
func TestContextNamePatternUseContext(t *testing.T) {
	checkContextForm(t, "use-context",
		`m.run("kubectl", "config", "use-context", "devzone")`,
		`m.run("kubectl", "config", "use-context", exec.ContextName())`)
}

// TestContextNamePatternSetContext: a set-context naming the literal is caught.
func TestContextNamePatternSetContext(t *testing.T) {
	checkContextForm(t, "set-context",
		`k.raw(ctx, "config", "set-context", "devzone", "--cluster="+c)`,
		`k.raw(ctx, "config", "set-context", exec.ContextName(), "--cluster="+c)`)
}

// TestContextNamePatternGetContexts: a context list checked against the
// literal on the same line is caught.
func TestContextNamePatternGetContexts(t *testing.T) {
	checkContextForm(t, "get-contexts",
		`s.run("kubectl", "config", "get-contexts", "-o", "name"); hasContext(out, "devzone")`,
		`s.run("kubectl", "config", "get-contexts", "-o", "name"); hasContext(out, wanted)`)
}

// TestContextNamePatternEquality: a comparison against the literal is caught.
func TestContextNamePatternEquality(t *testing.T) {
	checkContextForm(t, "equality",
		`if strings.TrimSpace(name) == "devzone" {`,
		`if strings.TrimSpace(name) == wanted {`)
}

// TestNoHardcodedDevzoneContext ensures the services context is never written
// by hand in Go production code: it must go through the shared helper.
func TestNoHardcodedDevzoneContext(t *testing.T) {
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
		if contextNameExcept[rel] {
			return nil
		}
		if strings.HasPrefix(rel, "internal/domain/gitlab/e2e/") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for i, line := range strings.Split(string(data), "\n") {
			if contextNamePattern.MatchString(line) {
				faults = append(faults, rel+":"+strconv.Itoa(i+1)+": "+strings.TrimSpace(line))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(faults) > 0 {
		t.Fatalf("hardcoded devzone context found:\n%s", strings.Join(faults, "\n"))
	}
}
