package argocd

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// gitopsFixture prepares a GitOps repository and the fake answers of its host.
func gitopsFixture(t *testing.T, conf string) *modFixture {
	t.Helper()
	f := newModFixture(t)
	writeTestFile(t, filepath.Join(f.root, ".argocd.conf"), conf)
	return f
}

// TestGitopsGitHubSkipsUnchangedFile checks that a blob already at the wanted
// sha is not written again, and that a different blob uses PUT with its sha.
func TestGitopsGitHubSkipsUnchangedFile(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	file := filepath.Join(t.TempDir(), "app.yaml")
	writeTestFile(t, file, "kind: Application\n")
	sha := gitBlobSHA([]byte("kind: Application\n"))
	shaArgs := []string{"api", "repos/tester/devzone-argocd/contents/apps/app.yaml", "--jq", ".sha"}
	f.r.On("gh", shaArgs, fexec.Result{Stdout: []byte(sha + "\n")})
	if code := newFixtureModule(t, f).gitopsPut("apps/app.yaml", file, "devzone: application app"); code != 0 {
		t.Fatalf("unchanged put: code=%d err=%q", code, f.err.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "gh" && strings.Contains(strings.Join(call.Args, " "), "-X PUT") {
			t.Fatalf("unchanged file was written: %v", call.Args)
		}
	}
	f.r.On("gh", shaArgs, fexec.Result{Stdout: []byte("deadbeef\n")})
	content := base64.StdEncoding.EncodeToString([]byte("kind: Application\n"))
	putArgs := []string{"api", "-X", "PUT", "repos/tester/devzone-argocd/contents/apps/app.yaml",
		"-f", "message=devzone: application app", "-f", "content=" + content, "-f", "sha=deadbeef"}
	f.r.On("gh", putArgs, fexec.Result{})
	if code := newFixtureModule(t, f).gitopsPut("apps/app.yaml", file, "devzone: application app"); code != 0 {
		t.Fatalf("changed put: code=%d err=%q", code, f.err.String())
	}
	if callIndex(f.r.Calls(), "gh", putArgs...) < 0 {
		t.Fatalf("no PUT call: %v", f.r.Calls())
	}
}

// TestGitopsGitHubDeleteAbsent checks that a missing file, whose host answers
// like a 404, is never deleted: a failed sha read is not a file to remove.
func TestGitopsGitHubDeleteAbsent(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	f.r.On("gh", []string{"api", "repos/tester/devzone-argocd/contents/apps/app.yaml", "--jq", ".sha"},
		fexec.Result{Code: 1, Stdout: []byte(`{"message":"Not Found","status":"404"}`), Stderr: []byte("gh: Not Found (HTTP 404)\n")})
	if code := newFixtureModule(t, f).gitopsDelete("apps/app.yaml", "devzone: application app removed"); code != 0 {
		t.Fatalf("delete: code=%d err=%q", code, f.err.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "-X DELETE") {
			t.Fatalf("absent file was deleted: %v", call.Args)
		}
	}
}

// TestGitopsGitLabInitKeepsTokenOutOfArguments checks that the root token is
// read from the disposable folder, used in headers only, and never written in
// the configuration file nor in the output.
func TestGitopsGitLabInitKeepsTokenOutOfArguments(t *testing.T) {
	f := gitopsFixture(t, "")
	dir := filepath.Join(f.root, "workspace", ".gitlab")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(dir, "root-token"), "glpat-SECRET\n")
	base := "http://gitlab.localhost:8929/api/v4"
	f.r.On("curl", []string{"-s", "--header", "PRIVATE-TOKEN: glpat-SECRET", base + "/groups/devzone"},
		fexec.Result{Stdout: []byte(`{"id":7}`)})
	f.r.On("curl", []string{"-s", "--header", "PRIVATE-TOKEN: glpat-SECRET", base + "/projects/devzone%2Fdevzone-argocd"},
		fexec.Result{Stdout: []byte(`{"id":42}`)})
	if code := newFixtureModule(t, f).gitlabGitopsInit(); code != 0 {
		t.Fatalf("init: code=%d err=%q", code, f.err.String())
	}
	conf, err := os.ReadFile(filepath.Join(f.root, ".argocd.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(conf), "glpat-SECRET") || strings.Contains(f.out.String(), "glpat-SECRET") || strings.Contains(f.err.String(), "glpat-SECRET") {
		t.Fatalf("token leaked: conf=%q out=%q err=%q", conf, f.out.String(), f.err.String())
	}
	if !strings.Contains(string(conf), "provider = gitlab") ||
		!strings.Contains(string(conf), "gitlab-webservice-default.devzone-gitlab.svc") {
		t.Fatalf("conf = %q", conf)
	}
}

// TestGitopsGitLabPutAndDelete checks the POST, PUT and DELETE verbs of the
// GitLab API and that an absent file is not deleted.
func TestGitopsGitLabPutAndDelete(t *testing.T) {
	f := gitopsFixture(t, "[argocd]\nprovider = gitlab\n")
	dir := filepath.Join(f.root, "workspace", ".gitlab")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(dir, "root-token"), "glpat-SECRET")
	base := "http://gitlab.localhost:8929/api/v4/projects/42/repository/files/apps%2Fapp.yaml"
	projectArgs := []string{"-s", "--header", "PRIVATE-TOKEN: glpat-SECRET", "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdevzone-argocd"}
	f.r.On("curl", projectArgs, fexec.Result{Stdout: []byte(`{"id":42}`)})
	shaArgs := []string{"-s", "--header", "PRIVATE-TOKEN: glpat-SECRET", base + "?ref=main"}
	f.r.On("curl", shaArgs, fexec.Result{Code: 1})
	f.r.On("curl", []string{"-s", "--request", "POST", "--header", "PRIVATE-TOKEN: glpat-SECRET",
		"--data-urlencode", "branch=main", "--data-urlencode", "encoding=base64",
		"--data-urlencode", "content=" + base64.StdEncoding.EncodeToString([]byte("kind: Application\n")),
		"--data-urlencode", "commit_message=devzone: application app", base}, fexec.Result{})
	file := filepath.Join(t.TempDir(), "app.yaml")
	writeTestFile(t, file, "kind: Application\n")
	m := newFixtureModule(t, f)
	if code := m.gitopsPut("apps/app.yaml", file, "devzone: application app"); code != 0 {
		t.Fatalf("put: code=%d err=%q", code, f.err.String())
	}
	post := callIndex(f.r.Calls(), "curl", "-s", "--request", "POST", "--header", "PRIVATE-TOKEN: glpat-SECRET",
		"--data-urlencode", "branch=main", "--data-urlencode", "encoding=base64",
		"--data-urlencode", "content="+base64.StdEncoding.EncodeToString([]byte("kind: Application\n")),
		"--data-urlencode", "commit_message=devzone: application app", base)
	if post < 0 {
		t.Fatalf("no POST call: %v", f.r.Calls())
	}
	if code := m.gitopsDelete("apps/app.yaml", "devzone: application app removed"); code != 0 {
		t.Fatalf("delete absent: code=%d err=%q", code, f.err.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "DELETE") {
			t.Fatalf("absent file was deleted: %v", call.Args)
		}
	}
}
