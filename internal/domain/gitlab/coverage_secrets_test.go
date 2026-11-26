package gitlab

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestSecrets600NeverShownNorInArguments checks the four secrets of the
// instance and the Rails secret: all 600, never displayed, never an argument
// of a command (gitlab.bats "secrets in workspace/.gitlab").
func TestSecrets600NeverShownNorInArguments(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d, stderr = %q", code, f.errStr())
	}
	for _, name := range []string{"root-password", "root-token", "runner-token", "dev-password", "rails-secret.yaml"} {
		if mode := f.modeOf("workspace/.gitlab/" + name); mode != "600" {
			t.Errorf("%s mode = %q, want 600", name, mode)
		}
	}
	if got := f.readFile("workspace/.gitlab/root-password"); got != "password123" {
		t.Errorf("root-password = %q", got)
	}
	for _, secret := range []string{"password123", "token-root-secret", "token-runner-secret"} {
		if strings.Contains(f.outStr()+f.errStr(), secret) {
			t.Errorf("secret shown: %q", secret)
		}
		for _, call := range f.calls() {
			if strings.Contains(call, secret) {
				t.Errorf("secret in the arguments of %q", call)
			}
		}
	}
}

// TestSecretsApplyBeforeHelmOnReinstall checks that a kept Rails secret is
// reapplied before the helm pass of a reinstallation (gitlab-secrets.bats).
func TestSecretsApplyBeforeHelmOnReinstall(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.r.On("kubectl", nil, exec.Result{})
	f.writeFile("workspace/.gitlab/rails-secret.yaml", `{"kind":"Secret"}`+"\n")
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d, stderr = %q", code, f.errStr())
	}
	apply, helm := -1, -1
	for i, call := range f.r.Calls() {
		line := call.Name + " " + strings.Join(call.Args, " ")
		if strings.Contains(line, "apply -f "+f.root+"/workspace/.gitlab/rails-secret.yaml") {
			apply = i
		}
		if call.Name == "helm" && strings.Contains(line, "upgrade --install gitlab") && helm < 0 {
			helm = i
		}
	}
	if apply < 0 || helm < 0 || apply > helm {
		t.Errorf("Rails secret applied at %d, helm at %d: %v", apply, helm, f.calls())
	}
}

// TestNewPasswordDevNeverInArguments checks the dev password: 600 file,
// grouped credentials, only the path shown and no secret in an argument
// (gitlab-secrets.bats "new-password dev" and "password absent from args").
func TestNewPasswordDevNeverInArguments(t *testing.T) {
	f := newFixture(t)
	f.programToolbox("OK")
	if code := f.run("new-password", "dev"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if mode := f.modeOf("workspace/.gitlab/dev-password"); mode != "600" {
		t.Errorf("dev-password mode = %q, want 600", mode)
	}
	if f.outStr() != f.root+"/.password\n" {
		t.Errorf("output = %q", f.outStr())
	}
	pass := f.readFile("workspace/.gitlab/dev-password")
	if !strings.Contains(f.readFile(".password"), "\tdev\t"+pass) {
		t.Errorf(".password = %q", f.readFile(".password"))
	}
	for _, call := range f.calls() {
		if strings.Contains(call, pass) {
			t.Errorf("generated password in the arguments of %q", call)
		}
	}
}

// TestSeedPushUsesCredentialHelper checks that the root token of the demo
// push is read by a Git credential helper, never put in a remote URL or an
// argument (the rule of secrets of the ticket).
func TestSeedPushUsesCredentialHelper(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", nil, exec.Result{})
	f.r.On("git", nil, exec.Result{})
	f.writeFile(".devcontainer/gitlab/demo/README.md", "demo\n")
	var branchCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		code, body := http.StatusOK, `{"id":42}`
		switch {
		case strings.Contains(req.URL.Path, "branches/main"):
			if atomic.AddInt32(&branchCalls, 1) == 1 {
				code = http.StatusNotFound
			}
		case strings.HasSuffix(req.URL.Path, "user/runners"):
			body = `{"token":"token-runner-secret"}`
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	testBaseURL = srv.URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("remote add origin http://gitlab.localhost:8929/devzone/demo.git") {
		t.Errorf("remote without token missing in %v", f.calls())
	}
	if !f.hasCall("credential.helper=!f()") || !f.hasCall("username=oauth2") {
		t.Errorf("no credential helper in %v", f.calls())
	}
	for _, call := range f.calls() {
		if strings.Contains(call, "token-root-secret") {
			t.Errorf("root token in an argument: %q", call)
		}
	}
}

// TestSeedFailureStopsInstall checks that a failed group creation stops the
// installation before the second helm pass, with the message of the shell
// (gitlab.bats "seed failure → installation fails").
func TestSeedFailureStopsInstall(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		code := http.StatusOK
		if req.URL.Path == "/api/v4/groups/devzone" {
			code = http.StatusNotFound
		}
		if req.Method == http.MethodPost && req.URL.Path == "/api/v4/groups" {
			code = http.StatusInternalServerError
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(`{"id":42}`))
	}))
	t.Cleanup(srv.Close)
	testBaseURL = srv.URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("install"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "devzone group") {
		t.Errorf("stderr = %q", f.errStr())
	}
	for _, call := range f.calls() {
		if strings.Contains(call, "gitlab-runner.replicas=1") {
			t.Errorf("runner pass after a failed seed: %q", call)
		}
	}
}

// TestSeedRunnerTokenNeverShown checks that a saved runner token is never
// shown nor passed as an argument (gitlab.bats "seed: runner token never shown").
func TestSeedRunnerTokenNeverShown(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", nil, exec.Result{})
	f.writeFile("workspace/.gitlab/runner-token", "token-runner-secret")
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	for _, call := range f.calls() {
		if strings.Contains(call, "token-runner-secret") {
			t.Errorf("runner token in an argument: %q", call)
		}
	}
	if strings.Contains(f.outStr()+f.errStr(), "token-runner-secret") {
		t.Error("runner token shown")
	}
}

// programToolbox programs the toolbox pod and a gitlab-rails runner answer.
func (f *fixture) programToolbox(answer string) {
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"},
		exec.Result{Stdout: []byte("gitlab-toolbox-1")})
	f.r.On("kubectl", []string{"--context", "devzone", "exec", "-i", "-n", "devzone-gitlab",
		"gitlab-toolbox-1", "--", "gitlab-rails", "runner", "-"},
		exec.Result{Stdout: []byte(answer)})
}
