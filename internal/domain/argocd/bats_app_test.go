package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBatsArgocdAppAdd mirrors the project Application bats test: the manifest
// is applied with the devzone context and the rendered fields are unchanged.
func TestBatsArgocdAppAdd(t *testing.T) {
	f := newModFixture(t)
	f.markInstalled(t)
	allowKubectl(f)
	code := f.run("app", "add", "https://github.com/argoproj/argocd-example-apps", "guestbook")
	if code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if !strings.Contains(f.out.String(), "✔ Application app-argocd-example-apps") {
		t.Fatalf("out=%q", f.out.String())
	}
	manifest := stdinFor(t, f.r.Calls(), "kubectl", devzoneKubectl("apply", "-f", "-")...)
	for _, want := range []string{
		"kind: Application", "name: app-argocd-example-apps",
		"devzone.io/kind: project", "path: guestbook",
		"namespace: devzone-app-argocd-example-apps",
	} {
		if !strings.Contains(manifest, want) {
			t.Fatalf("manifest missing %q: %s", want, manifest)
		}
	}
}

// TestBatsArgocdAppAddGitLab mirrors the GitLab bats test: the token is read
// from the instance root, never printed, and the repository URL is rewritten
// to the internal service URL with a repository Secret and a NetworkPolicy.
func TestBatsArgocdAppAddGitLab(t *testing.T) {
	f := newModFixture(t)
	f.markInstalled(t)
	allowKubectl(f)
	t.Setenv("DEVZONE_INSTANCE", "")
	gitlab := filepath.Join(f.root, "workspace", ".gitlab")
	if err := os.MkdirAll(gitlab, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(gitlab, "root-token"), "glpat-SECRET")
	code := f.run("app", "add", "http://gitlab.localhost:8929/devzone/demo.git", "k8s")
	if code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if strings.Contains(f.out.String()+f.err.String(), "glpat-SECRET") {
		t.Fatalf("token leaked: %q %q", f.out.String(), f.err.String())
	}
	calls := f.r.Calls()
	patch := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-gitlab", "patch", "networkpolicy", "devzone-meme-namespace", "--type", "merge", "-p", `{"spec":{"ingress":[{"from":[{"podSelector":{},"namespaceSelector":{"matchLabels":{"app.kubernetes.io/managed-by":"devzone"}}}]}]}}`)...)
	secret := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "apply", "-f", "-")...)
	app := callIndex(calls, "kubectl", devzoneKubectl("apply", "-f", "-")...)
	if patch < 0 || secret < 0 || app < 0 || !(patch < secret && secret < app) {
		t.Fatalf("unexpected app add order: %v", calls)
	}
	secretManifest := stdinFor(t, calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "apply", "-f", "-")...)
	internal := "http://gitlab-webservice-default.devzone-gitlab.svc:8181/devzone/demo.git"
	for _, want := range []string{"argocd.argoproj.io/secret-type: repository", "password: glpat-SECRET", "url: " + internal} {
		if !strings.Contains(secretManifest, want) {
			t.Fatalf("secret manifest missing %q: %s", want, secretManifest)
		}
	}
	if manifest := stdinFor(t, calls, "kubectl", devzoneKubectl("apply", "-f", "-")...); !strings.Contains(manifest, "repoURL: "+internal) {
		t.Fatalf("application manifest=%s", manifest)
	}
}
