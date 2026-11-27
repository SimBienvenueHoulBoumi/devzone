package create

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestConfSetFreshFile checks a missing file starts with the header and gets
// one [argocd] section with `key = value`, blank lines squeezed.
func TestConfSetFreshFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".argocd.conf")
	if err := confSet(path, "argocd", "repo", "none"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	s := string(data)
	if !strings.Contains(s, "Argo CD of devzone") {
		t.Fatalf("no header:\n%s", s)
	}
	if !strings.HasSuffix(s, "[argocd]\n    repo = none\n") {
		t.Fatalf("section:\n%s", s)
	}
}

// TestConfSetReplacesOnlySection checks an existing [argocd] section is
// replaced, other sections and comments are kept, repeated blanks squeezed.
func TestConfSetReplacesOnlySection(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".argocd.conf")
	original := "# comment\n\n\n[argocd]\n    repo = old\n    other = x\n\n[app demo]\n    repo = https://example.com\n"
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := confSet(path, "argocd", "repo", "https://github.com/a/b.git"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	s := string(data)
	if strings.Contains(s, "repo = old") || strings.Contains(s, "other = x") {
		t.Fatalf("old argocd kept:\n%s", s)
	}
	if !strings.Contains(s, "[app demo]\n    repo = https://example.com") {
		t.Fatalf("app section lost:\n%s", s)
	}
	if !strings.Contains(s, "# comment") {
		t.Fatalf("comment lost:\n%s", s)
	}
	if !strings.HasSuffix(s, "[argocd]\n    repo = https://github.com/a/b.git\n") {
		t.Fatalf("new section:\n%s", s)
	}
	if strings.Contains(s, "\n\n\n") {
		t.Fatalf("blanks not squeezed:\n%s", s)
	}
}

// TestConfSetGolden checks the exact bytes confSet writes for the edge cases
// of the shared format: comments inside the replaced section, a section name
// with spaces, a file without a trailing newline. The expectations are literal
// so the test stays hermetic (no shell is run) and pins the format the
// workstation and the pod read back.
func TestConfSetGolden(t *testing.T) {
	cases := []struct {
		name     string
		original string
		value    string
		want     string
	}{
		{"fresh", "", "none", confHeader + "\n[argocd]\n    repo = none\n"},
		{"url", "", "https://github.com/login/devzone-argocd.git", confHeader + "\n[argocd]\n    repo = https://github.com/login/devzone-argocd.git\n"},
		{"existing argocd", "[argocd]\n    repo = old\n", "none", "\n[argocd]\n    repo = none\n"},
		{"existing other", "[argocd]\n    repo = old\n\n[app demo]\n    repo = x\n", "https://example.com/y.git", "[app demo]\n    repo = x\n\n[argocd]\n    repo = https://example.com/y.git\n"},
		{"comments", "# hi\n\n[argocd]\n# c\n    repo = old\n", "none", "# hi\n\n[argocd]\n    repo = none\n"},
		{"no trailing newline", "[app demo]\n    repo = x", "none", "[app demo]\n    repo = x\n\n[argocd]\n    repo = none\n"},
		{"section name with spaces", "[ argocd ]\n    repo = old\n", "none", "\n[argocd]\n    repo = none\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".argocd.conf")
			if c.original != "" {
				if err := os.WriteFile(path, []byte(c.original), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if err := confSet(path, "argocd", "repo", c.value); err != nil {
				t.Fatal(err)
			}
			got, _ := os.ReadFile(path)
			if string(got) != c.want {
				t.Fatalf("got:\n%q\nwant:\n%q", got, c.want)
			}
		})
	}
}
