package argocd

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestBatsGitlabApplicationThroughArgoCD mirrors the GitLab-on-Argo-CD bats
// test with Go commands: the chart is accepted and the Application manifest
// carries the runner URL, without a helm installation.
func TestBatsGitlabApplicationThroughArgoCD(t *testing.T) {
	f := heldFixture(t, "gitlab")
	allowKubectl(f)
	t.Setenv("DEVZONE_INSTANCE", "")
	if code := f.run("catalog-active", "gitlab"); code != 0 {
		t.Fatalf("catalog-active: code=%d err=%q", code, f.err.String())
	}
	if code := f.run("chart-require", "gitlab"); code != 0 {
		t.Fatalf("chart-require: code=%d err=%q", code, f.err.String())
	}
	url := "http://gitlab-webservice-default.devzone-gitlab.svc:8181"
	code := f.run("gitops-apply", "devzone-gitlab", "service", "devzone-gitlab",
		"https://example.invalid/devzone.git", "v1.2.3", "charts/devzone-gitlab",
		"gitlab-runner.gitlabUrl="+url)
	if code != 0 {
		t.Fatalf("gitops-apply: code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	manifest := stdinFor(t, f.r.Calls(), "kubectl", devzoneKubectl("apply", "-f", "-")...)
	for _, want := range []string{"kind: Application", "name: devzone-gitlab", "path: charts/devzone-gitlab", "name: gitlab-runner.gitlabUrl", "value: \"" + url + "\""} {
		if !strings.Contains(manifest, want) {
			t.Fatalf("manifest missing %q: %s", want, manifest)
		}
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm used: %q", joinedArgs(call))
		}
	}
}

// TestBatsGitlabUnknownRevisionFails mirrors the development-clone bats test:
// with Argo CD on, an unknown revision is an explicit failure, never a return
// to the direct helm path.
func TestBatsGitlabUnknownRevisionFails(t *testing.T) {
	f := newModFixture(t)
	f.markInstalled(t)
	allowKubectl(f)
	writeChart(t, f.root, "gitlab", "devzone-gitlab")
	writeTestFile(t, filepath.Join(f.root, "package.json"), "{\"version\": \"0.0.0\"}\n")
	if code := f.run("catalog-active", "gitlab"); code != 2 {
		t.Fatalf("catalog-active: code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if !strings.Contains(f.err.String(), "DEVZONE_ARGOCD_REVISION") {
		t.Fatalf("the failure does not say how to set a revision: %q", f.err.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm was called: %q", joinedArgs(call))
		}
	}
}
