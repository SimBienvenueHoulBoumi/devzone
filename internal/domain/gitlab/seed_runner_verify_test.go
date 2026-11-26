package gitlab

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// TestSeedRunnerTokenVerifyUsesPost checks that the saved runner token is
// verified with a POST and that the codes 200, 403 and 500 keep, recreate and
// stop the seed.
func TestSeedRunnerTokenVerifyUsesPost(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		wantCode int
		wantErr  string
	}{
		{"200 kept", http.StatusOK, 0, ""},
		{"403 recreated", http.StatusForbidden, 0, ""},
		{"500 stopped", http.StatusInternalServerError, 1, "check impossible (code 500)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.programSeed()
			f.writeFile("workspace/.gitlab/runner-token", "token-runner-secret")
			var mu sync.Mutex
			method := ""
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/api/v4/runners/verify" {
					mu.Lock()
					method = r.Method
					mu.Unlock()
					w.WriteHeader(tc.status)
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
			if code := f.run("seed"); code != tc.wantCode {
				t.Fatalf("seed: code = %d, want %d, stderr = %q", code, tc.wantCode, f.errStr())
			}
			mu.Lock()
			got := method
			mu.Unlock()
			if got != http.MethodPost {
				t.Errorf("verify method = %q, want POST", got)
			}
			if tc.wantErr != "" && !strings.Contains(f.errStr(), tc.wantErr) {
				t.Errorf("stderr = %q, want %q", f.errStr(), tc.wantErr)
			}
			if got := f.readFile("workspace/.gitlab/runner-token"); got != "token-runner-secret" {
				t.Errorf("runner-token = %q", got)
			}
		})
	}
}
