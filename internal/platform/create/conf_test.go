package create

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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

// TestConfSetParityWithConfSh compares byte for byte with the real
// conf_set in .devcontainer/argocd/conf.sh sourced in bash (#884 rule).
func TestConfSetParityWithConfSh(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash tests run on Unix only")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is not installed")
	}
	script, err := filepath.Abs(filepath.Join("..", "..", ".devcontainer", "argocd", "conf.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(script); err != nil {
		t.Skip("conf.sh not found")
	}
	cases := []struct {
		name     string
		original string
		value    string
	}{
		{"fresh", "", "none"},
		{"url", "", "https://github.com/login/devzone-argocd.git"},
		{"existing argocd", "[argocd]\n    repo = old\n", "none"},
		{"existing other", "[argocd]\n    repo = old\n\n[app demo]\n    repo = x\n", "https://example.com/y.git"},
		{"comments", "# hi\n\n[argocd]\n# c\n    repo = old\n", "none"},
		{"no trailing newline", "[app demo]\n    repo = x", "none"},
		{"section name with spaces", "[ argocd ]\n    repo = old\n", "none"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			bashDir := t.TempDir()
			bashPath := filepath.Join(bashDir, ".argocd.conf")
			if c.original != "" {
				if err := os.WriteFile(bashPath, []byte(c.original), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			cmd := exec.Command("bash", "-c", `. "$1"; conf_set argocd "repo=$2"`, "_", script, c.value)
			cmd.Env = append(os.Environ(), "ARGOCD_CONF="+bashPath, "LC_ALL=C")
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("conf_set: %v\n%s", err, out)
			}
			goDir := t.TempDir()
			goPath := filepath.Join(goDir, ".argocd.conf")
			if c.original != "" {
				if err := os.WriteFile(goPath, []byte(c.original), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if err := confSet(goPath, "argocd", "repo", c.value); err != nil {
				t.Fatal(err)
			}
			want, _ := os.ReadFile(bashPath)
			got, _ := os.ReadFile(goPath)
			if string(want) != string(got) {
				t.Fatalf("bash:\n%q\ngo:\n%q", want, got)
			}
		})
	}
}
