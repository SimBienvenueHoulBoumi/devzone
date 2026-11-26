package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestE2ENameFailures checks step 3: unresolved name, foreign address and a
// stopped relay, each with the exact reason of the shell script.
func TestE2ENameFailures(t *testing.T) {
	for _, tc := range []struct {
		name, out, want string
		code            int
	}{
		{"unresolved", "", "gitlab.localhost not resolved", 2},
		{"foreign", "172.17.0.1 gitlab.localhost", "resolves to 172.17.0.1, expected 127.0.0.1", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			f.r.On("getent", []string{"hosts", "gitlab.localhost"}, exec.Result{Stdout: []byte(tc.out), Code: tc.code})
			if code := f.run(); code == 0 {
				t.Fatal("code = 0, want failure")
			}
			for _, want := range []string{"✖ 3. host name", tc.want} {
				if !strings.Contains(f.out.String(), want) {
					t.Errorf("output lacks %q: %s", want, f.out.String())
				}
			}
		})
	}
	f := newFixture(t)
	f.r.On(scriptName(), []string{"gitlab", "relay-status"},
		exec.Result{Stdout: []byte("gitlab relay stopped on 8929 2224\n"), Code: 1})
	if code := f.run(); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	if !strings.Contains(f.out.String(), "gitlab relay stopped on 8929 2224") {
		t.Errorf("output = %q", f.out.String())
	}
}

// TestE2ECloneCredentialHelper checks that the HTTP clone uses a credential
// helper reading the token file: no token in an argument or a message.
func TestE2ECloneCredentialHelper(t *testing.T) {
	f := newFixture(t)
	if code := f.run(); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !f.hasCall("credential.helper=!f()") || !f.hasCall("username=oauth2") {
		t.Errorf("no credential helper in %v", f.calls())
	}
	for _, call := range f.calls() {
		if strings.Contains(call, "token-root-secret") {
			t.Errorf("token in an argument: %q", call)
		}
	}
}

// TestE2ECloneFailures checks the reasons of step 5 and the guaranteed key
// removal when the HTTP clone fails.
func TestE2ECloneFailures(t *testing.T) {
	for _, tc := range []struct {
		name, fail, want string
		keyFail          bool
	}{
		{"key upload", "", "SSH key upload", true},
		{"ssh clone", "ssh://git@", "SSH clone", false},
		{"http clone", "", "HTTP clone", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			if tc.keyFail {
				f.keyBody = "fail"
			}
			if tc.fail != "" {
				f.failGit = tc.fail
			}
			if tc.name == "http clone" {
				f.failGit = f.server.URL
			}
			if code := f.run(); code == 0 {
				t.Fatal("code = 0, want failure")
			}
			for _, want := range []string{"✖ 5. HTTP and SSH clones", tc.want} {
				if !strings.Contains(f.out.String(), want) {
					t.Errorf("output lacks %q: %s", want, f.out.String())
				}
			}
			if strings.Contains(f.out.String(), "token-root-secret") {
				t.Error("token shown")
			}
		})
	}
}

// TestE2ETokenInCloneConfig checks the refusal of a clone whose .git/config
// holds the token, with the key removed by the cleanup.
func TestE2ETokenInCloneConfig(t *testing.T) {
	f := newFixture(t)
	config := filepath.Join(f.clones, "http-demo", ".git", "config")
	if err := os.MkdirAll(filepath.Dir(config), 0o755); err != nil {
		t.Fatal(err)
	}
	f.write(config, "extraheader = PRIVATE-TOKEN: token-root-secret\n")
	if code := f.run(); code == 0 {
		t.Fatal("code = 0, want failure")
	}
	for _, want := range []string{"✖ 5. HTTP and SSH clones", "written to .git/config"} {
		if !strings.Contains(f.out.String(), want) {
			t.Errorf("output lacks %q: %s", want, f.out.String())
		}
	}
	if !strings.Contains(strings.Join(f.apiCalls, "\n"), "DELETE /api/v4/user/keys/7") {
		t.Errorf("key not removed: %v", f.apiCalls)
	}
}
