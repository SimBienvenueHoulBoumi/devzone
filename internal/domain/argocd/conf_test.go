package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfGet(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".argocd.conf")
	if err := os.WriteFile(path, []byte(`# header comment
[argocd]
    repo = https://github.com/me/devzone-argocd.git   # inline comment

[app demo]
    repo = https://github.com/argoproj/argocd-example-apps
    path = guestbook
    revision=main

[ app spaced ]
    repo = https://x/y.git
`), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Conf{Path: path}
	if got := c.Get("argocd", "repo"); got != "https://github.com/me/devzone-argocd.git" {
		t.Fatalf("got %q", got)
	}
	if got := c.Get("app demo", "path"); got != "guestbook" {
		t.Fatalf("got %q", got)
	}
	if got := c.Get("app demo", "revision"); got != "main" {
		t.Fatalf("got %q", got)
	}
	if got := c.Get("app spaced", "repo"); got != "https://x/y.git" {
		t.Fatalf("got %q", got)
	}
	if got := c.Get("app demo", "namespace"); got != "" {
		t.Fatalf("got %q", got)
	}
	if got := c.Get("missing", "repo"); got != "" {
		t.Fatalf("got %q", got)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if got := c.Get("argocd", "repo"); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestConfSections(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".argocd.conf")
	if err := os.WriteFile(path, []byte(`[argocd]
    repo = x
[app demo]
    repo = a
[ app spaced ]
    repo = b
`), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Conf{Path: path}
	got := strings.Join(c.Sections("app"), " ")
	if got != "demo spaced" {
		t.Fatalf("got %q", got)
	}
	if names := c.Sections("other"); len(names) != 0 {
		t.Fatalf("got %v", names)
	}
}

func TestConfSetRemove(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".argocd.conf")
	if err := os.WriteFile(path, []byte("# header comment\n[argocd]\n    repo = https://github.com/me/devzone-argocd.git   # inline comment\n\n[app demo]\n    repo = https://github.com/argoproj/argocd-example-apps\n    path = guestbook\n    revision=main\n\n[ app spaced ]\n    repo = https://x/y.git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Conf{Path: path}
	if err := c.Set("app demo", "repo=https://new/demo.git", "path=."); err != nil {
		t.Fatal(err)
	}
	if got := c.Get("app demo", "repo"); got != "https://new/demo.git" {
		t.Fatalf("got %q", got)
	}
	if got := c.Get("app demo", "revision"); got != "" {
		t.Fatalf("got %q", got)
	}
	data, _ := os.ReadFile(path)
	if strings.Count(string(data), "[app demo]") != 1 {
		t.Fatalf("section duplicated: %s", data)
	}
	if !strings.Contains(string(data), "# header comment") {
		t.Fatalf("header lost: %s", data)
	}
	if got := c.Get("argocd", "repo"); got != "https://github.com/me/devzone-argocd.git" {
		t.Fatalf("got %q", got)
	}
	if err := c.Set("app third", "repo=https://x/third.git"); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(c.Sections("app"), " "); got != "spaced demo third" {
		t.Fatalf("got %q", got)
	}
	if err := c.Remove("app spaced"); err != nil {
		t.Fatal(err)
	}
	if got := c.Get("app spaced", "repo"); got != "" {
		t.Fatalf("got %q", got)
	}
	if got := strings.Join(c.Sections("app"), " "); got != "demo third" {
		t.Fatalf("got %q", got)
	}
	data, _ = os.ReadFile(path)
	if strings.Contains(string(data), "https://x/y.git") {
		t.Fatalf("removed content still present: %s", data)
	}
	if strings.Contains(string(data), "\n\n\n") {
		t.Fatalf("too many blank lines: %q", string(data))
	}
}

func TestConfSetCreatesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".argocd.conf")
	c := Conf{Path: path}
	if err := c.Set("argocd", "repo=none"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "# Argo CD of devzone") {
		t.Fatalf("missing header: %s", data)
	}
	if got := c.Get("argocd", "repo"); got != "none" {
		t.Fatalf("got %q", got)
	}
}
