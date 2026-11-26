package gitlab

import (
	"crypto/rand"
	"io"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"strings"
	"sync"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// specialBase64Reader yields a fixed byte pattern whose base64 output holds
// the characters + and /, so the dev password of a test is deterministic.
type specialBase64Reader struct {
	pattern []byte
	i       int
}

// Read fills p with the repeating pattern.
func (r *specialBase64Reader) Read(p []byte) (int, error) {
	for j := range p {
		p[j] = r.pattern[r.i%len(r.pattern)]
		r.i++
	}
	return len(p), nil
}

// TestSeedRootTokenScriptNeedsPuts checks that the gitlab-rails runner only
// returns a token when the received script prints it: the seed writes that
// token (the old script lacked the puts and got an empty answer).
func TestSeedRootTokenScriptNeedsPuts(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/user/runners": `{"token":"token-runner-secret"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	code := f.runWithScriptedRails(func(script string) exec.Result {
		if strings.Contains(script, "puts") {
			return exec.Result{Stdout: []byte("token-root-secret\n")}
		}
		return exec.Result{}
	}, "seed")
	if code != 0 {
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	if got := f.readFile("workspace/.gitlab/root-token"); got != "token-root-secret" {
		t.Errorf("root-token = %q", got)
	}
}

// TestSeedRootTokenEmptyOutputFails checks that an empty answer of the
// gitlab-rails runner stops the seed with its original message and never
// overwrites an existing root token.
func TestSeedRootTokenEmptyOutputFails(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	f.writeFile("workspace/.gitlab/root-token", "old-root-token")
	testBaseURL = serverOf(t, nil).URL
	t.Cleanup(func() { testBaseURL = "" })
	code := f.runWithScriptedRails(func(string) exec.Result { return exec.Result{} }, "seed")
	if code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "creation of the root token") {
		t.Errorf("stderr = %q", f.errStr())
	}
	if got := f.readFile("workspace/.gitlab/root-token"); got != "old-root-token" {
		t.Errorf("root-token = %q, want old-root-token", got)
	}
}

// TestSeedDevPasswordFormKeepsBase64 checks that a dev password with + and /
// reaches the server intact: the form is decoded and compared with the
// dev-password file.
func TestSeedDevPasswordFormKeepsBase64(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	oldReader := rand.Reader
	rand.Reader = &specialBase64Reader{pattern: []byte{0xFB, 0xFF, 0xBF}}
	t.Cleanup(func() { rand.Reader = oldReader })
	var mu sync.Mutex
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/api/v4/users" {
			data, _ := io.ReadAll(r.Body)
			mu.Lock()
			body = string(data)
			mu.Unlock()
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
		t.Fatalf("seed: code = %d, stderr = %q", code, f.errStr())
	}
	dev := f.readFile("workspace/.gitlab/dev-password")
	if !strings.ContainsAny(dev, "+/") {
		t.Fatalf("generated password %q has no + nor /", dev)
	}
	values, err := neturl.ParseQuery(body)
	if err != nil {
		t.Fatalf("form %q: %v", body, err)
	}
	if got := values.Get("password"); got != dev {
		t.Errorf("received password = %q, want %q (form %q)", got, dev, body)
	}
}

// TestSeedDevUserCreationFailureStops checks that a failed creation of the dev
// user stops the seed.
func TestSeedDevUserCreationFailureStops(t *testing.T) {
	f := newFixture(t)
	f.programSeed()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/api/v4/users" {
			w.WriteHeader(http.StatusInternalServerError)
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
	if code := f.run("seed"); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.errStr(), "creation of the dev user failed") {
		t.Errorf("stderr = %q", f.errStr())
	}
}
