package argocd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// fixtureSawCall reports whether a recorded call of name has all the parts in its arguments
func fixtureSawCall(f *modFixture, name string, parts ...string) bool {
	for _, call := range f.r.Calls() {
		if call.Name != name {
			continue
		}
		joined := strings.Join(call.Args, " ")
		ok := true
		for _, p := range parts {
			if !strings.Contains(joined, p) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// TestRemoveApplicationFileGitHubDeletesThenRefreshes checks that the file of the
// Application leaves the GitHub repository with its sha, then that the root
// Application is annotated to refresh at once.
func TestRemoveApplicationFileGitHubDeletesThenRefreshes(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	f.r.On("gh", []string{"api", "repos/tester/devzone-argocd/contents/apps/devzone-workspace.yaml", "--jq", ".sha"},
		fexec.Result{Stdout: []byte("abc123\n")})
	f.r.On("gh", []string{"api", "-X", "DELETE", "repos/tester/devzone-argocd/contents/apps/devzone-workspace.yaml",
		"-f", "message=devzone: application devzone-workspace removed", "-f", "sha=abc123"}, fexec.Result{})
	if code := RemoveApplicationFile(context.Background(), f.opts(), "devzone-workspace"); code != 0 {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
	if !fixtureSawCall(f, "gh", "-X DELETE", "sha=abc123") {
		t.Fatalf("no DELETE of the file: %v", f.r.Calls())
	}
	if !fixtureSawCall(f, "kubectl", "annotate", "application.argoproj.io", gitopsRootApp, "argocd.argoproj.io/refresh=normal") {
		t.Fatalf("root Application not refreshed: %v", f.r.Calls())
	}
}

// TestRemoveApplicationFileGitHubRefusalStops checks that a repository that
// refuses the DELETE makes the removal fail with 1, and that the root
// Application is not refreshed: the file is still there.
func TestRemoveApplicationFileGitHubRefusalStops(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	f.r.On("gh", []string{"api", "repos/tester/devzone-argocd/contents/apps/devzone-workspace.yaml", "--jq", ".sha"},
		fexec.Result{Stdout: []byte("abc123\n")})
	f.r.On("gh", []string{"api", "-X", "DELETE", "repos/tester/devzone-argocd/contents/apps/devzone-workspace.yaml",
		"-f", "message=devzone: application devzone-workspace removed", "-f", "sha=abc123"},
		fexec.Result{Code: 1, Stderr: []byte("HTTP 403\n")})
	if code := RemoveApplicationFile(context.Background(), f.opts(), "devzone-workspace"); code != 1 {
		t.Fatalf("code=%d, want 1 when GitHub refuses the DELETE", code)
	}
	if fixtureSawCall(f, "kubectl", "annotate") {
		t.Fatalf("root Application refreshed after a refusal: %v", f.r.Calls())
	}
}

// TestRemoveApplicationFileGitHubSHAReadFailureStops checks that a gh api
// failure that is not "file absent" stops the removal with 1, as the old shell
// did with "sha=$(... || return 1)": the Application must stay in the cluster.
func TestRemoveApplicationFileGitHubSHAReadFailureStops(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	f.r.On("gh", []string{"api", "repos/tester/devzone-argocd/contents/apps/devzone-workspace.yaml", "--jq", ".sha"},
		fexec.Result{Code: 1, Stderr: []byte("HTTP 500\n")})
	if code := RemoveApplicationFile(context.Background(), f.opts(), "devzone-workspace"); code != 1 {
		t.Fatalf("code=%d, want 1 when gh api cannot read the sha", code)
	}
	if fixtureSawCall(f, "gh", "-X", "DELETE") || fixtureSawCall(f, "kubectl", "annotate") {
		t.Fatalf("removal continued after a sha read failure: %v", f.r.Calls())
	}
}

// TestRemoveApplicationFileWithoutRepositoryDoesNothing checks that without a
// designated GitOps repository no command runs: the Application is applied
// directly, so there is no file to remove.
func TestRemoveApplicationFileWithoutRepositoryDoesNothing(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = none\n")
	if code := RemoveApplicationFile(context.Background(), f.opts(), "devzone-workspace"); code != 0 {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls without a repository: %v", f.r.Calls())
	}
}

// TestRemoveApplicationFileGitLabDeletesFile checks that a GitLab repository
// receives the DELETE of the file through its API, with the same root token
// header as the other GitOps calls, and not through gh.
func TestRemoveApplicationFileGitLabDeletesFile(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nprovider = gitlab\nrepo = http://gitlab-webservice-default.devzone-gitlab.svc:8181/devzone/devzone-argocd.git\n")
	dir := filepath.Join(f.root, "workspace", ".gitlab")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(dir, "root-token"), "glpat-SECRET")
	base := "http://gitlab.localhost:8929/api/v4/projects/42/repository/files/apps%2Fdevzone-workspace.yaml"
	f.r.On("curl", []string{"-s", "--header", "PRIVATE-TOKEN: glpat-SECRET",
		"http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdevzone-argocd"}, fexec.Result{Stdout: []byte(`{"id":42}`)})
	f.r.On("curl", []string{"-s", "--header", "PRIVATE-TOKEN: glpat-SECRET", base + "?ref=main"},
		fexec.Result{Stdout: []byte(`{"blob_id":"abc123"}`)})
	f.r.On("curl", []string{"-s", "--request", "DELETE", "--header", "PRIVATE-TOKEN: glpat-SECRET",
		"--data-urlencode", "branch=main", "--data-urlencode", "commit_message=devzone: application devzone-workspace removed", base}, fexec.Result{})
	if code := RemoveApplicationFile(context.Background(), f.opts(), "devzone-workspace"); code != 0 {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
	if !fixtureSawCall(f, "curl", "DELETE", base) {
		t.Fatalf("no GitLab DELETE of the file: %v", f.r.Calls())
	}
	if fixtureSawCall(f, "gh") {
		t.Fatalf("gh called for a GitLab repository: %v", f.r.Calls())
	}
}
