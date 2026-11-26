package gitlab

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// namespaceResult returns the runner answer of a present or absent namespace.
func namespaceResult(present bool) exec.Result {
	code := 0
	if !present {
		code = 1
	}
	return exec.Result{Code: code}
}

// onNamespace programs the get namespace call of installed().
func (f *fixture) onNamespace(present bool) {
	f.r.On("kubectl", nil, namespaceResult(present))
}

// serverOf starts a server answering 200 by default and the given paths with
// the given body and status.
func serverOf(t *testing.T, paths map[string]string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if body, ok := paths[r.URL.Path]; ok {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(body))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":42}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestStatusDisabled checks the output "disabled" without namespace (gitlab.bats).
func TestStatusDisabled(t *testing.T) {
	f := newFixture(t)
	f.onNamespace(false)
	if code := f.run("status"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.outStr() != "disabled\n" {
		t.Fatalf("output = %q", f.outStr())
	}
}

// TestStatusReadyOffline checks "ready: http://gitlab.localhost:8929, runner
// offline" (gitlab.bats).
func TestStatusReadyOffline(t *testing.T) {
	f := newFixture(t)
	f.onNamespace(true)
	f.writeFile("workspace/.gitlab/root-token", "token-root-secret\n")
	testBaseURL = serverOf(t, nil).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("status"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.outStr() != "ready: http://gitlab.localhost:8929, runner offline\n" {
		t.Fatalf("output = %q", f.outStr())
	}
}

// TestStatusReadyOnline checks "runner online" when the API of the runners
// answers an online runner (gitlab.bats).
func TestStatusReadyOnline(t *testing.T) {
	f := newFixture(t)
	f.onNamespace(true)
	f.writeFile("workspace/.gitlab/root-token", "token-root-secret\n")
	testBaseURL = serverOf(t, map[string]string{"/api/v4/runners/all": "[{\"id\":1}]"}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("status"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.outStr() != "ready: http://gitlab.localhost:8929, runner online\n" {
		t.Fatalf("output = %q", f.outStr())
	}
}

// TestStatusFailed checks "failed: devzone apply" when GitLab does not answer
// (gitlab.bats).
func TestStatusFailed(t *testing.T) {
	f := newFixture(t)
	f.onNamespace(true)
	testBaseURL = failingServer(t).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("status"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if f.outStr() != "failed: devzone apply\n" {
		t.Fatalf("output = %q", f.outStr())
	}
}

// failingServer starts a server answering 500 (curl -sf fails).
func failingServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestInstalled checks the presence of the namespace (gitlab.bats).
func TestInstalled(t *testing.T) {
	f := newFixture(t)
	f.onNamespace(true)
	if code := f.run("installed"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	f.onNamespace(false)
	if code := f.run("installed"); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
}

// TestUnknownCommands checks the message and code of the shell entry point
// for unknown subcommands (gitlab.sh case).
func TestUnknownCommands(t *testing.T) {
	f := newFixture(t)
	for _, args := range [][]string{
		{"nosuch"},
		{},
		{"--help"},
	} {
		if code := f.run(args...); code != 1 {
			t.Fatalf("code = %d for %v", code, args)
		}
		want := "devzone : unknown command : "
		if len(args) > 0 {
			want += strings.Join(args, " ")
		}
		if !strings.Contains(f.errStr(), want+" (devzone gitlab --help)") {
			t.Fatalf("stderr = %q for %v", f.errStr(), args)
		}
		f.reset()
	}
}
