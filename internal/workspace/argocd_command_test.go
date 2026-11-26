package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestArgocdStatusNotInstalled checks that a missing namespace is a status
// line, as in the shell, and that no Applications are asked for.
func TestArgocdStatusNotInstalled(t *testing.T) {
	r := &fakeRunner{replies: []reply{{match: "get namespace devzone-argocd", status: 1}, {match: ""}}}
	var out bytes.Buffer
	if status := argocdStatus(r, filepath.Join(t.TempDir(), ".argocd.conf"), "", &out); status != 0 {
		t.Fatalf("status = %d", status)
	}
	want := "○ argocd not installed: devzone workspace services enable argocd\n"
	if out.String() != want {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
	for _, call := range r.calls {
		if strings.Contains(call, "applications.argoproj.io") {
			t.Fatalf("Applications were read without Argo CD: %q", r.calls)
		}
	}
}

// TestArgocdStatusInstalled checks the installed line, the GitOps repository
// read from .argocd.conf through the shared library, and the indented table.
func TestArgocdStatusInstalled(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, ".argocd.conf")
	content := "[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n"
	if err := os.WriteFile(conf, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	table := "APPLICATION KIND SYNC HEALTH REVISION\nworkspace workspace Synced Healthy v1.2.3\n"
	r := &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "get namespace devzone-argocd", status: 0},
		{match: "get applications.argoproj.io", stdout: table},
		{match: ""},
	}}
	t.Setenv("ARGOCD_PORT", "9443")
	var out bytes.Buffer
	if status := argocdStatus(r, conf, filepath.Join(dir, ".devzone.modules"), &out); status != 0 {
		t.Fatalf("status = %d", status)
	}
	want := "✔ argocd installed: https://localhost:9443 (devzone workspace ports), user admin, password in .password\n" +
		"  GitOps repository: https://github.com/tester/devzone-argocd.git (apps/, root Application devzone)\n" +
		"  APPLICATION KIND SYNC HEALTH REVISION\n" +
		"  workspace workspace Synced Healthy v1.2.3\n"
	if out.String() != want {
		t.Fatalf("out = %q, want %q", out.String(), want)
	}
}

// TestArgocdStatusOffAndDirect checks the warning for argocd=off and the
// direct-apply line when no GitOps repository is designated.
func TestArgocdStatusOffAndDirect(t *testing.T) {
	dir := t.TempDir()
	modules := filepath.Join(dir, ".devzone.modules")
	if err := os.WriteFile(modules, []byte("argocd=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := &fakeRunner{replies: []reply{
		{match: "config get-contexts"},
		{match: "get namespace devzone-argocd", status: 0},
		{match: ""},
	}}
	var out bytes.Buffer
	argocdStatus(r, filepath.Join(dir, "absent.conf"), modules, &out)
	if !strings.Contains(out.String(), "argocd installed but argocd=off") ||
		!strings.Contains(out.String(), "no GitOps repository: Applications applied directly") {
		t.Fatalf("out = %q", out.String())
	}
}
