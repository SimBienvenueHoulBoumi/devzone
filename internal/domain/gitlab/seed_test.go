package gitlab

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// recordingServer starts a server answering 200 and recording the POSTs.
func recordingServer(t *testing.T, posts *[]string) *httptest.Server {
	t.Helper()
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			body, _ := io.ReadAll(r.Body)
			mu.Lock()
			*posts = append(*posts, r.URL.Path+" "+string(body))
			mu.Unlock()
		}
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{"id":42,"token":"token-runner-secret","status":"success"}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestSeedRunnerTokenKept200 checks that the saved runner token is kept when
// it is still valid (gitlab.bats "seed: runner-token present and verified 200
// → token kept, no creation").
func TestSeedRunnerTokenKept200(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", nil, exec.Result{})

	f.programSeedBase()
	f.r.On("kubectl", nil, exec.Result{})
	f.writeFile("workspace/.gitlab/runner-token", "token-runner-secret")
	testBaseURL = serverOf(t, nil).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if got := f.readFile("workspace/.gitlab/runner-token"); got != "token-runner-secret" {
		t.Errorf("runner-token = %q", got)
	}
}

// TestSeedRunnerTokenRefused403 checks the recreation of a refused token
// (gitlab.bats "seed: runner-token present and refused 403 → token
// recreated, file overwritten").
func TestSeedRunnerTokenRefused403(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", nil, exec.Result{})

	f.programSeedBase()
	f.r.On("kubectl", nil, exec.Result{})
	f.writeFile("workspace/.gitlab/runner-token", "old-runner-token")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v4/runners/verify" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if strings.HasSuffix(r.URL.Path, "user/runners") {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"token":"token-runner-secret"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":42}`))
	}))
	t.Cleanup(srv.Close)
	testBaseURL = srv.URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if got := f.readFile("workspace/.gitlab/runner-token"); got != "token-runner-secret" {
		t.Errorf("runner-token = %q", got)
	}
	if !strings.Contains(f.outStr(), "refused: recreated") {
		t.Errorf("output = %q", f.outStr())
	}
}

// TestSeedRunnerTokenCheckImpossible checks the stop of the seed when the
// check is unreachable (gitlab.bats "seed: runner token check unreachable →
// seed stopped").
func TestSeedRunnerTokenCheckImpossible(t *testing.T) {
	f := newFixture(t)

	f.programSeedBase()
	f.r.On("kubectl", nil, exec.Result{})
	f.writeFile("workspace/.gitlab/runner-token", "token-runner-secret")
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	dead.Close()
	testBaseURL = dead.URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code == 0 {
		t.Fatal("code = 0, want != 0")
	}
	if !strings.Contains(f.errStr(), "timeout waiting for GitLab") && !strings.Contains(f.errStr(), "seed stopped") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestSeedDemoNotPushedAgain checks that a rerun skips the push when the
// main branch already exists (gitlab.bats "installation rerun -> demo project
// not pushed again").
func TestSeedDemoNotPushedAgain(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.r.On("kubectl", nil, exec.Result{})
	f.r.On("git", nil, exec.Result{})
	f.writeFile(".devcontainer/gitlab/demo/README.md", "demo\n")
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/projects/devzone%2Fdemo/repository/branches/main": `{"name":"main"}`,
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	for _, c := range f.r.Calls() {
		if c.Name == "git" && len(c.Args) > 0 && c.Args[0] == "push" {
			t.Errorf("push called on rerun: %v", c.Args)
		}
	}
	if !strings.Contains(f.outStr(), "demo project already pushed") {
		t.Errorf("output = %q", f.outStr())
	}
}
