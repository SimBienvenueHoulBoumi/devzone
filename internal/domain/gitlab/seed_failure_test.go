package gitlab

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestSeedInitialRootPasswordKubectlCodeStops checks that a non-zero kubectl
// code when reading the initial root password stops the seed even when the
// output holds a valid base64 value.
func TestSeedInitialRootPasswordKubectlCodeStops(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", []string{"--context", "devzone", "get", "secret", "-n", "devzone-gitlab",
		"gitlab-gitlab-initial-root-password", "-o", "jsonpath={.data.password}"},
		exec.Result{Stdout: []byte("cGFzc3dvcmQxMjM="), Code: 1})
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "root secret") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestSeedToolboxKubectlCodeStops checks that a non-zero kubectl code when
// reading the toolbox pod stops the seed even when the output holds a name.
func TestSeedToolboxKubectlCodeStops(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"},
		exec.Result{Stdout: []byte("gitlab-toolbox-1"), Code: 1})
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "toolbox pod") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestSeedSigningKeyCodeStops checks that a non-zero gitlab-rails code when
// creating the ci_job_token_signing_key stops the seed.
func TestSeedSigningKeyCodeStops(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	code := f.runWithScriptedRails(func(script string) exec.Result {
		if strings.Contains(script, "ci_job_token_signing_key") {
			return exec.Result{Code: 1}
		}
		return exec.Result{Stdout: []byte("token-root-secret\n")}
	}, "seed")
	if code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "ci_job_token_signing_key") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestSeedRunnerSecretCreateCodeStops checks that a non-zero kubectl code when
// creating the YAML of the runner Secret stops the seed even when the output
// holds a manifest.
func TestSeedRunnerSecretCreateCodeStops(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", []string{"--context", "devzone", "create", "secret",
		"generic", "gitlab-runner-secret", "--from-file=runner-token=" + f.secretsDir() + "/runner-token",
		"--from-literal=runner-registration-token=", "--dry-run=client", "-o", "yaml"},
		exec.Result{Stdout: []byte("apiVersion: v1\nkind: Secret\n"), Code: 1})
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "gitlab-runner-secret not created") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestSeedRunnerSecretApplyCodeStops checks that a non-zero kubectl code when
// applying the runner Secret stops the seed.
func TestSeedRunnerSecretApplyCodeStops(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-gitlab",
		"apply", "-f", "-"}, exec.Result{Code: 1})
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "gitlab-runner-secret not created") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestInstallChartDependCodeStops checks that a non-zero helm dependency build
// stops the installation before the chart pass.
func TestInstallChartDependCodeStops(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.r.On("helm", []string{"dependency", "build", f.root + "/charts/devzone-gitlab"},
		exec.Result{Code: 1})
	if code := f.run("install"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if f.hasCall("upgrade --install gitlab") {
		t.Errorf("helm pass after a failed dependency build: %v", f.calls())
	}
}

// TestInstallWaitReadyTimeoutStops checks that a GitLab that never becomes
// ready stops the installation with a non-zero code.
func TestInstallWaitReadyTimeoutStops(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/-/readiness" || r.URL.Path == "/users/sign_in":
			w.WriteHeader(http.StatusInternalServerError)
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
	if code := f.run("install"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "timeout waiting for GitLab") {
		t.Errorf("stderr = %q", f.errStr())
	}
}
