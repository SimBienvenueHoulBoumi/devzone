package gitlab

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestSeedGroupsAndProject checks the creation of the group devzone and the
// project devzone/demo with the numeric group ID (gitlab.bats "project
// created with the numeric group ID").
func TestSeedGroupsAndProject(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", nil, exec.Result{})
	f.programSeed()
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-gitlab", "apply", "-f", "-"}, exec.Result{})
	var mu sync.Mutex
	var posts []string
	created := map[string]bool{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			body, _ := io.ReadAll(r.Body)
			mu.Lock()
			posts = append(posts, r.URL.Path+" "+string(body))
			if r.URL.Path == "/api/v4/groups" {
				created["group"] = true
			} else if r.URL.Path == "/api/v4/projects" {
				created["project"] = true
			}
			mu.Unlock()
		}
		mu.Lock()
		group, project := created["group"], created["project"]
		mu.Unlock()
		switch {
		case r.URL.Path == "/api/v4/groups/devzone" && !group:
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/api/v4/projects/devzone/demo" && !project:
			w.WriteHeader(http.StatusNotFound)
		case strings.HasSuffix(r.URL.Path, "user/runners"):
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"token":"token-runner-secret"}`))
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"id":42}`))
		}
	}))
	t.Cleanup(srv.Close)
	testBaseURL = srv.URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	joined := strings.Join(posts, "\n")
	if !strings.Contains(joined, "name=devzone&path=devzone&visibility=private") {
		t.Errorf("no group creation in %v", posts)
	}
	if !strings.Contains(joined, "name=demo") {
		t.Errorf("no project creation in %v", posts)
	}
}

// TestSeedCiJobTokenSigningKey checks the creation of the
// ci_job_token_signing_key through gitlab-rails runner when it is missing
// (the default of a reinstallation without Rails secret): one call through
// the runner holds the script setting the ApplicationSetting value.
func TestSeedCiJobTokenSigningKey(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", nil, exec.Result{})
	f.r.On("kubectl", []string{"--context", "devzone", "get", "secret", "-n", "devzone-gitlab",
		"gitlab-gitlab-initial-root-password", "-o", "jsonpath={.data.password}"},
		exec.Result{Stdout: []byte("cGFzc3dvcmQxMjM=")})
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"},
		exec.Result{Stdout: []byte("gitlab-toolbox-1")})
	f.r.On("kubectl", []string{"--context", "devzone", "exec", "-i", "-n", "devzone-gitlab",
		"gitlab-toolbox-1", "--", "gitlab-rails", "runner", "-"}, exec.Result{Stdout: []byte("token-root-secret\n")})
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-gitlab", "create", "secret",
		"generic", "gitlab-runner-secret", "--from-file=runner-token=" + f.secretsDir() + "/runner-token",
		"--from-literal=runner-registration-token=", "--dry-run=client", "-o", "yaml"},
		exec.Result{Stdout: []byte("apiVersion: v1\nkind: Secret\n")})
	testBaseURL = serverOf(t, map[string]string{"/api/v4/user/runners": `{"token":"token-runner-secret"}`}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	scripts := ""
	for _, c := range f.r.Calls() {
		if c.Name == "kubectl" && c.Opts.Stdin != nil {
			if data, err := io.ReadAll(c.Opts.Stdin); err == nil {
				scripts += string(data) + "\n"
			}
		}
	}
	if !strings.Contains(scripts, "ApplicationSetting") || !strings.Contains(scripts, "ci_job_token_signing_key") ||
		!strings.Contains(scripts, "SecureRandom.hex(32)") {
		t.Errorf("no script setting ci_job_token_signing_key in the runner calls: %v", scripts)
	}
}

// TestSeedRunnerTokenMissingCreates checks that a missing runner token is
// created through the API and written (gitlab.bats "seed: runner-token missing
// -> token created").
func TestSeedRunnerTokenMissingCreates(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", nil, exec.Result{})
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	if got := f.readFile("workspace/.gitlab/runner-token"); got != "token-runner-secret" {
		t.Errorf("runner-token = %q", got)
	}
}

// TestSeedRunnerSecretWritesKubectl checks the call of the seed writing the
// Secret gitlab-runner-secret out of Git (gitlab-argocd.bats).
func TestSeedRunnerSecretWritesKubectl(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", nil, exec.Result{})

	f.programSeedBase()
	f.r.On("kubectl", nil, exec.Result{})
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"},
		exec.Result{Stdout: []byte("gitlab-toolbox-1")})
	f.writeFile("workspace/.gitlab/runner-token", "token-runner-secret")
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/runners/verify": "200",
		"/api/v4/user/runners":   `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("create secret generic gitlab-runner-secret") {
		t.Fatalf("no secret creation in calls: %v", f.calls())
	}
	if !f.hasCall("--from-literal=runner-registration-token=") {
		t.Fatalf("no empty runner-registration-token in calls: %v", f.calls())
	}
	if !f.hasCall(fmt.Sprintf("--from-file=runner-token=%s/runner-token", f.secretsDir())) {
		t.Fatalf("no runner-token file in calls: %v", f.calls())
	}
}
