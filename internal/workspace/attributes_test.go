package workspace

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// referencePath reports whether a repository-relative path is a reference
// file: anything under a testdata or golden folder, and any .golden or .txt file.
func referencePath(path string) bool {
	parts := strings.Split(filepath.ToSlash(path), "/")
	for _, part := range parts {
		if part == "testdata" || part == "golden" || part == "goldens" {
			return true
		}
	}
	name := parts[len(parts)-1]
	return strings.HasSuffix(name, ".golden") || strings.HasSuffix(name, ".txt")
}

// lfRuleMatches reports whether a gitattributes pattern with eol=lf covers a
// path. Only the patterns used by this repository need support: a basename
// glob such as *.txt, and a **/folder/** rule matching a folder at any depth.
func lfRuleMatches(pattern, path string) bool {
	if !strings.Contains(pattern, "/") {
		name := path[strings.LastIndex(path, "/")+1:]
		ok, _ := filepath.Match(pattern, name)
		return ok
	}
	parts := strings.Split(pattern, "/")
	if len(parts) != 3 || parts[0] != "**" || parts[2] != "**" {
		return false
	}
	segments := strings.Split(path, "/")
	for i := 0; i+1 < len(segments); i++ {
		if segments[i] == parts[1] {
			return true
		}
	}
	return false
}

// TestGitattributesKeepsReferencesLF checks that every reference file of the
// repository is covered by an eol=lf rule. Without it a Windows checkout with
// core.autocrlf writes CRLF bytes in golden files and embedded data, which the
// golden comparison and the binaries built there then see.
func TestGitattributesKeepsReferencesLF(t *testing.T) {
	root := filepath.Join("..", "..")
	data, err := os.ReadFile(filepath.Join(root, ".gitattributes"))
	if err != nil {
		t.Fatal(err)
	}
	var rules []string
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		for _, field := range fields {
			if field == "eol=lf" {
				rules = append(rules, fields[0])
				break
			}
		}
	}
	if len(rules) == 0 {
		t.Fatal(".gitattributes has no eol=lf rule")
	}
	found := 0
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".essai", "node_modules", "vendor", "workspace":
				return fs.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if !referencePath(rel) {
			return nil
		}
		found++
		for _, rule := range rules {
			if lfRuleMatches(rule, rel) {
				return nil
			}
		}
		t.Errorf("reference file %s is not covered by an eol=lf rule in .gitattributes", rel)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found == 0 {
		t.Fatal("no reference file found: the check would cover nothing")
	}
}
