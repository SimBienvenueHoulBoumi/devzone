package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	rule "github.com/SimBienvenueHoulBoumi/devzone/internal/platform/argocd"
)

// stubValuesExists replaces the GitOps file reader of one test, so no host
// program is started by the status command.
func stubValuesExists(t *testing.T, present bool) {
	t.Helper()
	previous := valuesExists
	t.Cleanup(func() { valuesExists = previous })
	valuesExists = func(string, string) bool { return present }
}

// TestWorkspaceValuesLine checks the reported path and presence for a GitOps
// repository, and that no file is looked up without one.
func TestWorkspaceValuesLine(t *testing.T) {
	for _, tc := range []struct {
		name    string
		repo    string
		present bool
		want    string
	}{
		{"present", "https://github.com/tester/devzone-argocd.git", true,
			"  devzone-workspace values: " + rule.WorkspaceValuesPath + " (present)\n"},
		{"absent", "https://github.com/tester/devzone-argocd.git", false,
			"  devzone-workspace values: " + rule.WorkspaceValuesPath + " (absent)\n"},
		{"no repository", "", false,
			"  devzone-workspace values: not used (no GitOps repository)\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			previous := valuesExists
			t.Cleanup(func() { valuesExists = previous })
			valuesExists = func(string, string) bool {
				called = true
				return tc.present
			}
			if got := workspaceValuesLine(tc.repo, rule.WorkspaceValuesPath); got != tc.want {
				t.Fatalf("line = %q, want %q", got, tc.want)
			}
			if tc.repo == "" && called {
				t.Fatal("a values file was looked up without a GitOps repository")
			}
		})
	}
}

// TestArgocdStatusValuesAbsent checks that the whole status command reports an
// absent values file instead of hiding it.
func TestArgocdStatusValuesAbsent(t *testing.T) {
	stubValuesExists(t, false)
	dir := t.TempDir()
	conf := filepath.Join(dir, ".argocd.conf")
	if err := os.WriteFile(conf, []byte("[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "get namespace devzone-argocd", status: 0},
		{match: ""},
	}}
	var out bytes.Buffer
	if code := argocdStatus(r, conf, filepath.Join(dir, ".devzone.modules"), &out); code != 0 {
		t.Fatalf("status = %d", code)
	}
	want := "  devzone-workspace values: " + rule.WorkspaceValuesPath + " (absent)\n"
	if !strings.Contains(out.String(), want) {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
}
