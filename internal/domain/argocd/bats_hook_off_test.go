package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestBatsHookPostgresOff mirrors the off-with-Application bats test: the
// Application is deleted with cascade and the hook exits 3 for the helm path.
func TestBatsHookPostgresOff(t *testing.T) {
	f := heldFixture(t, "postgres")
	allowKubectl(f)
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-postgres"), fexec.Result{})
	if code := f.run("services-hook", "postgres", "off"); code != 3 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	calls := f.r.Calls()
	deleted := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "delete", "application.argoproj.io", "devzone-postgres", "--ignore-not-found", "--wait=true")...)
	if deleted < 0 {
		t.Fatalf("no cascade delete: %v", calls)
	}
	for _, call := range calls {
		if call.Name == "kubectl" && strings.Contains(joinedArgs(call), "patch application.argoproj.io") {
			t.Fatalf("finalizer patched on cascade delete: %q", joinedArgs(call))
		}
	}
	if got := newFixtureModule(t, f).conf().Get("services", "postgres"); got != "off" {
		t.Fatalf("services postgres = %q", got)
	}
}

// TestBatsHookPostgresOffAbsent mirrors the off-without-Application bats test:
// no deletion happens and the hook exits 3.
func TestBatsHookPostgresOffAbsent(t *testing.T) {
	f := heldFixture(t, "postgres")
	allowKubectl(f)
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-postgres"), fexec.Result{Code: 1})
	if code := f.run("services-hook", "postgres", "off"); code != 3 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && strings.Contains(joinedArgs(call), "delete application.argoproj.io") {
			t.Fatalf("deleted an absent Application: %q", joinedArgs(call))
		}
	}
}

// TestBatsHookArgocdOffRelease mirrors the argocd-off bats test: finalizers
// are dropped before the keep deletion, GitLab is released and MySQL is absent.
func TestBatsHookArgocdOffRelease(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeTestFile(t, f.state, "argocd=on\n")
	for _, app := range []string{"devzone-postgres", "devzone-gitlab"} {
		f.r.On("kubectl", devzoneKubectl("-n", "devzone-argocd", "get", "application.argoproj.io", app), fexec.Result{})
	}
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-mysql"), fexec.Result{Code: 1})
	if code := f.run("services-hook", "argocd", "off"); code != 3 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	calls := f.r.Calls()
	patch := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "patch", "application.argoproj.io", "devzone-postgres", "--type", "merge", "-p", `{"metadata":{"finalizers":null}}`)...)
	deleted := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "delete", "application.argoproj.io", "devzone-postgres", "--ignore-not-found", "--wait=true")...)
	gitlab := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "delete", "application.argoproj.io", "devzone-gitlab", "--ignore-not-found", "--wait=true")...)
	if patch < 0 || deleted < 0 || gitlab < 0 || patch > deleted {
		t.Fatalf("unexpected release order: %v", calls)
	}
	for _, call := range calls {
		if call.Name == "kubectl" && strings.Contains(joinedArgs(call), "devzone-mysql") && !strings.Contains(joinedArgs(call), "get application.argoproj.io") {
			t.Fatalf("absent MySQL touched: %q", joinedArgs(call))
		}
	}
	if got := newFixtureModule(t, f).conf().Get("services", "postgres"); got != "off" {
		t.Fatalf("services postgres = %q", got)
	}
	if got := newFixtureModule(t, f).conf().Get("services", "mysql"); got != "" {
		t.Fatalf("services mysql = %q", got)
	}
}

// TestBatsServicesSecretPostgres mirrors the secret bats test: the password is
// created apart, mirrored with mode 600 and never written to the output.
func TestBatsServicesSecretPostgres(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	if code := newFixtureModule(t, f).servicesSecret("postgres"); code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if f.out.String() != "" || f.err.String() != "" {
		t.Fatalf("secret printed: %q %q", f.out.String(), f.err.String())
	}
	file := filepath.Join(f.root, "workspace", ".postgres", "admin-password")
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) == 0 || info.Mode().Perm() != 0o600 {
		t.Fatalf("secret=%q mode=%v", data, info.Mode().Perm())
	}
	if !hasCall(f.r.Calls(), "kubectl", devzoneKubectl("-n", "devzone-postgres", "create", "secret", "generic", "postgres-admin", "--from-file=password="+file)...) {
		t.Fatalf("secret not created: %v", f.r.Calls())
	}
}
