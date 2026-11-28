//go:build !windows

package checks

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// newNamesRepo creates a local repository in a disposable folder.
func newNamesRepo(t *testing.T) string {
	t.Helper()
	testkit.RequireGit(t)
	root := t.TempDir()
	testkit.Git(t, root, "init", "-q")
	return root
}

// touchNamesFile creates an empty file at path in the repository.
func touchNamesFile(t *testing.T, root, path string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

// runNamesCheck runs the name check and returns its output and code.
func runNamesCheck(t *testing.T, root string) (string, int) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := RunNames(root, &out, &errOut)
	if errOut.Len() > 0 {
		t.Fatalf("unexpected stderr: %s", errOut.String())
	}
	return out.String(), code
}

// TestNamesAcceptsEnglishPaths covers English names and allowed user data.
func TestNamesAcceptsEnglishPaths(t *testing.T) {
	root := newNamesRepo(t)
	touchNamesFile(t, root, "manage/scripts/uninstall.sh")
	touchNamesFile(t, root, "state.sh")
	touchNamesFile(t, root, ".devzone.modules")
	touchNamesFile(t, root, ".devzone.version")
	output, code := runNamesCheck(t, root)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; output %q", code, output)
	}
	if !strings.HasPrefix(output, "names check: ") || !strings.HasSuffix(output, " paths ok\n") {
		t.Errorf("output = %q, want the ok line", output)
	}
}

// TestNamesRejectsFrenchFileName checks a file name with a forbidden word.
func TestNamesRejectsFrenchFileName(t *testing.T) {
	root := newNamesRepo(t)
	touchNamesFile(t, root, "manage/scripts/desinstaller.sh")
	output, code := runNamesCheck(t, root)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output %q", code, output)
	}
	if !strings.Contains(output, "manage/scripts/desinstaller.sh: desinstaller") {
		t.Errorf("output = %q, want the path and the word", output)
	}
}

// TestNamesRejectsFrenchFolderName checks a folder name with a forbidden word.
func TestNamesRejectsFrenchFolderName(t *testing.T) {
	root := newNamesRepo(t)
	touchNamesFile(t, root, "catalogue/app.sh")
	output, code := runNamesCheck(t, root)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output %q", code, output)
	}
	if !strings.Contains(output, "catalogue/app.sh: catalogue") {
		t.Errorf("output = %q, want the path and the word", output)
	}
}

// TestNamesRejectsFormerDataAndSkipsGithub checks both name rules at once.
func TestNamesRejectsFormerDataAndSkipsGithub(t *testing.T) {
	root := newNamesRepo(t)
	touchNamesFile(t, root, ".devzone.paquets")
	touchNamesFile(t, root, ".github/workflows/fonctionnel.yml")
	output, code := runNamesCheck(t, root)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output %q", code, output)
	}
	if !strings.Contains(output, ".devzone.paquets: paquets") {
		t.Errorf("output = %q, want the former data name", output)
	}
	if strings.Contains(output, "fonctionnel") {
		t.Errorf("output = %q, want no report for .github", output)
	}
}
