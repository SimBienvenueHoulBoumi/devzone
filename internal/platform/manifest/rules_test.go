package manifest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPathAllowed checks the paths a poisoned manifest may name: only the
// package's own folders and root files pass, every traversal form is refused.
func TestPathAllowed(t *testing.T) {
	cases := map[string]bool{
		".devcontainer/devzone":        true,
		"manage/scripts/devzone-x.sh":  true,
		"core/devzone":                 true,
		"scripts/launch.sh":            true,
		"Makefile":                     true,
		"LICENSE":                      true,
		"":                             false,
		"../dehors/secret":             false,
		"/etc/x":                       false,
		"a/../../dehors/secret":        false,
		".devcontainer/../../dehors/x": false,
		"workspace/x":                  false,
		"manage//x":                    false,
		"manage/./x":                   false,
		"manage/x\ny":                  false,
		"manage/x\ty":                  false,
		"package.json":                 false,
		"node_modules/x":               false,
	}
	for rel, want := range cases {
		if got := PathAllowed(rel); got != want {
			t.Errorf("PathAllowed(%q) = %v, want %v", rel, got, want)
		}
	}
}

// TestIsProtected checks that the user's own files are never touched, even when a
// manifest lists them.
func TestIsProtected(t *testing.T) {
	for _, rel := range []string{"workspace", "workspace/app/x", ".devzone.version", ".devzone.modules",
		".devzone.modules-kind", ".devzone.packages", ".password", ".app", ".devzone.log", ".git", ".git/config"} {
		if !IsProtected(rel) {
			t.Errorf("IsProtected(%q) = false", rel)
		}
	}
	for _, rel := range []string{"Makefile", "manage/devzone", ".devcontainer/devzone", ".gitignore"} {
		if IsProtected(rel) {
			t.Errorf("IsProtected(%q) = true", rel)
		}
	}
}

// TestInsideFolderRefusesLinkOut checks that a folder reached through a link that
// points outside of the devzone is refused, and a normal one is accepted.
func TestInsideFolderRefusesLinkOut(t *testing.T) {
	base := t.TempDir()
	folder := filepath.Join(base, "dz")
	outside := filepath.Join(base, "dehors")
	for _, d := range []string{folder, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(outside, filepath.Join(folder, "manage")); err != nil {
		t.Skip("symbolic links not available:", err)
	}
	if !InsideFolder(folder, "Makefile") {
		t.Error("a file at the root was refused")
	}
	if InsideFolder(folder, "manage/x") {
		t.Error("a folder linked outside was accepted")
	}
}

// TestOldTreeNeedsMarkerFiles checks that an old core/ or scripts/ is recognized
// only by its marker files.
func TestOldTreeNeedsMarkerFiles(t *testing.T) {
	folder := t.TempDir()
	writeFile(t, folder, "scripts/launch.sh", "")
	if OldTree(folder, "scripts") {
		t.Error("scripts/ without uninstall.sh recognized")
	}
	writeFile(t, folder, "scripts/uninstall.sh", "")
	if !OldTree(folder, "scripts") {
		t.Error("scripts/ with its two files not recognized")
	}
	writeFile(t, folder, "core/devzone", "")
	if !OldTree(folder, "core") {
		t.Error("core/ with its marker not recognized")
	}
	if OldTree(folder, "other") {
		t.Error("an unknown tree recognized")
	}
}

// TestKnownOldFile checks that only the files the package once delivered are
// known: the user's own files in an old tree are not.
func TestKnownOldFile(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "manage/scripts/launch.sh", "")
	cases := map[string]bool{
		"core/devzone":           true,
		"core/test/x.bats":       true,
		"core/docs/x.md":         true,
		"core/scripts/launch.sh": true,
		"scripts/launch.sh":      true,
		"scripts/mine.sh":        false,
		"core/mine/x":            false,
		"other/launch.sh":        false,
	}
	for rel, want := range cases {
		if got := KnownOldFile(root, rel); got != want {
			t.Errorf("KnownOldFile(%q) = %v, want %v", rel, got, want)
		}
	}
}

// TestCompleteGitignoreKeepsUserLines checks that the missing lines are added,
// the user's own lines stay, and a last line without newline is closed first.
func TestCompleteGitignoreKeepsUserLines(t *testing.T) {
	folder := t.TempDir()
	if err := os.WriteFile(filepath.Join(folder, ".gitignore"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := CompleteGitignore(folder); err != nil {
		t.Fatal(err)
	}
	if err := CompleteGitignore(folder); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(folder, ".gitignore"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if lines[0] != "mine" || lines[1] != GitignoreLines[0] {
		t.Fatalf("first lines = %q", lines[:2])
	}
	for _, want := range GitignoreLines {
		if n := count(lines, want); n != 1 {
			t.Errorf("%q appears %d times, want 1", want, n)
		}
	}
}

// count returns how many lines equal s.
func count(lines []string, s string) int {
	n := 0
	for _, l := range lines {
		if l == s {
			n++
		}
	}
	return n
}
