package testhygiene

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var (
	rawGitCommand  = regexp.MustCompile(`(?:Command|CommandContext)\s*\([^\n]*"git"`)
	helperGitCall  = regexp.MustCompile(`(?:testkit|testhygiene)\.Git\s*\(`)
	mainHelperCall = regexp.MustCompile(`(?:testkit\.|testhygiene\.)?Main\s*\(m\)`)
	testMainDecl   = regexp.MustCompile(`func\s+TestMain\s*\(m\s+\*testing\.M\)`)
	prodGitCall    = regexp.MustCompile(`(?:Run|Command|CommandContext)\s*\([^\n]*"git"`)
)

// packageGitState records how the Go files of one package call git.
type packageGitState struct {
	hasTests, runsGit, runsGitInCode, hasCleanMain bool
}

// TestGitTestsUseSharedHelper refuses a test that starts git without the
// common helper, or a package whose git calls have no TestMain cleaning the
// environment. Both would let a hook's GIT_DIR capture the test's repository.
func TestGitTestsUseSharedHelper(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	states := make(map[string]*packageGitState)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".essai", "node_modules", "vendor":
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		text := string(data)
		state := states[filepath.Dir(rel)]
		if state == nil {
			state = &packageGitState{}
			states[filepath.Dir(rel)] = state
		}
		if !strings.HasSuffix(path, "_test.go") {
			if prodGitCall.MatchString(text) {
				state.runsGitInCode = true
			}
			return nil
		}
		state.hasTests = true
		if strings.HasPrefix(filepath.ToSlash(rel), "internal/framework/testhygiene/") {
			// The helper's own tests demonstrate the hazard with raw git.
			state.runsGit = helperGitCall.MatchString(text) || rawGitCommand.MatchString(text)
		} else if rawGitCommand.MatchString(text) {
			t.Errorf("%s starts git directly; use the shared helper", rel)
		}
		if helperGitCall.MatchString(text) || rawGitCommand.MatchString(text) {
			state.runsGit = true
		}
		if testMainDecl.MatchString(text) && mainHelperCall.MatchString(text) {
			state.hasCleanMain = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for dir, state := range states {
		if state.hasTests && (state.runsGit || state.runsGitInCode) && !state.hasCleanMain {
			t.Errorf("package %s runs git but has no TestMain calling the shared helper", dir)
		}
	}
}
