package gitlab

import (
	"os"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestInstanceSuffix checks that the instance suffix is taken into account
// for the namespace: DEVZONE_INSTANCE=other → devzone-gitlab-other
// (gitlab.bats "suffixed instance → namespace devzone-gitlab-<instance>").
func TestInstanceSuffix(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_INSTANCE", "other")
	f.r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "-o", "json"},
		exec.Result{Stdout: []byte(`{"kind":"Namespace","metadata":{"name":"devzone-gitlab-other"}}`)})
	if code := f.run("status"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("get namespace devzone-gitlab-other") {
		t.Errorf("expected call to 'get namespace devzone-gitlab-other', got: %v", f.calls())
	}
}

// TestNewPasswordRoot checks the root password: file written 600, path only
// on the output (gitlab-secrets.bats "new-password root regenerates the
// password, shows only the path").
func TestNewPasswordRoot(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"},
		exec.Result{Stdout: []byte("gitlab-toolbox-1")})
	f.r.On("kubectl", []string{"--context", "devzone", "exec", "-i", "-n", "devzone-gitlab", "gitlab-toolbox-1",
		"--", "gitlab-rails", "runner", "-"}, exec.Result{Stdout: []byte("OK\n")})
	if code := f.run("new-password", "root"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	data := f.readFile("workspace/.gitlab/root-password")
	if data == "" {
		t.Fatal("root-password missing")
	}
	if mode := f.modeOf("workspace/.gitlab/root-password"); mode != "600" {
		t.Errorf("mode = %s, want 600", mode)
	}
	if !strings.Contains(f.outStr(), f.root+"/.password") {
		t.Errorf("output = %q", f.outStr())
	}
	if !strings.Contains(f.readFile(".password"), "gitlab\thttp://gitlab.localhost:8929\troot\t") {
		t.Errorf(".password = %q", f.readFile(".password"))
	}
	// The password must not appear in the kubectl arguments
	pass := f.readFile("workspace/.gitlab/root-password")
	for _, c := range f.calls() {
		if strings.Contains(c, pass) {
			t.Errorf("password should not appear in kubectl arguments: %s", c)
		}
	}
}

// TestNewPasswordWithoutOK checks the refusal without the OK marker
// (gitlab-secrets.bats "new-password without OK → file unchanged, non-zero").
func TestNewPasswordWithoutOK(t *testing.T) {
	f := newFixture(t)
	f.writeFile("workspace/.gitlab/root-password", "old-password\n")
	f.r.On("kubectl", nil, exec.Result{})
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"},
		exec.Result{Stdout: []byte("gitlab-toolbox-1")})
	f.r.On("kubectl", []string{"--context", "devzone", "exec", "-i", "-n", "devzone-gitlab", "gitlab-toolbox-1",
		"--", "gitlab-rails", "runner", "-"}, exec.Result{Stdout: []byte("false\n")})
	if code := f.run("new-password", "root"); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if f.readFile("workspace/.gitlab/root-password") != "old-password\n" {
		t.Errorf("root-password changed")
	}
}

// TestNewPasswordUnknownUser checks the refusal of an unknown user
// (gitlab-secrets.bats "new-password: unknown user -> code 2").
func TestNewPasswordUnknownUser(t *testing.T) {
	f := newFixture(t)
	if code := f.run("new-password", "admin"); code != 2 {
		t.Fatalf("code = %d, want 2", code)
	}
	if !strings.Contains(f.errStr(), "devzone : gitlab : unknown user : admin") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestNewPasswordToolboxMissing checks the refusal without the toolbox pod.
func TestNewPasswordToolboxMissing(t *testing.T) {
	f := newFixture(t)
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pod", "-n", "devzone-gitlab",
		"-l", "app=toolbox", "-o", "jsonpath={.items[0].metadata.name}"}, exec.Result{})
	if code := f.run("new-password", "root"); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(f.errStr(), "toolbox pod (label app=toolbox) not found, password not changed.") {
		t.Errorf("stderr = %q", f.errStr())
	}
}

// TestRailsSecretCopied600 checks that the Rails secret of the cluster is
// copied to workspace/.gitlab/rails-secret.yaml, 600, without the fields of
// the cluster (gitlab-secrets.bats "Rails secret copied to
// workspace/.gitlab (600), never shown").
func TestRailsSecretCopied600(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.r.On("kubectl", []string{"--context", "devzone", "get", "secret", "-n", "devzone-gitlab",
		"gitlab-rails-secret", "-o", "json"},
		exec.Result{Stdout: []byte(`{"kind":"Secret","metadata":{"name":"gitlab-rails-secret","namespace":"devzone-gitlab","resourceVersion":"123","uid":"abc"}}`)})
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d, stderr = %q", code, f.errStr())
	}
	data := f.readFile("workspace/.gitlab/rails-secret.yaml")
	if !strings.Contains(data, "Secret") {
		t.Errorf("rails-secret.yaml = %q", data)
	}
	if mode := f.modeOf("workspace/.gitlab/rails-secret.yaml"); mode != "600" {
		t.Errorf("mode = %s, want 600", mode)
	}
	for _, gone := range []string{"resourceVersion", "uid"} {
		if strings.Contains(data, gone) {
			t.Errorf("rails-secret.yaml keeps %s", gone)
		}
	}
	if strings.Contains(f.outStr(), "c2VjcmV0") {
		t.Errorf("the secret was shown: %q", f.outStr())
	}
}

// TestRailsSecretMissing checks that nothing is written when the secret is
// missing (gitlab-secrets.bats "Rails secret missing → no file, no empty file").
func TestRailsSecretMissing(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.r.On("kubectl", []string{"--context", "devzone", "get", "secret", "-n", "devzone-gitlab",
		"gitlab-rails-secret", "-o", "json"}, exec.Result{Stdout: []byte("")})
	if code := f.run("install"); code != 0 {
		t.Fatalf("install: code = %d, stderr = %q", code, f.errStr())
	}
	if _, err := os.Stat(f.root + "/workspace/.gitlab/rails-secret.yaml"); !os.IsNotExist(err) {
		t.Errorf("rails-secret.yaml present: %v", err)
	}
}
