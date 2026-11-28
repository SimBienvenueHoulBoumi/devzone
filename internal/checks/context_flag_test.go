package checks

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestNoHardcodedDevzoneContext ensures the services context is never written
// by hand in Go production code: it must go through the shared helper.
func TestNoHardcodedDevzoneContext(t *testing.T) {
	root, err := RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	pattern := regexp.MustCompile(`"--context", *"devzone"|--context devzone|--kube-context`)
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
		if rel == "internal/framework/exec/context.go" {
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
			if pattern.MatchString(line) {
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
