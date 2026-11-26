package argocd

import (
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestBatsHookPostgresOnHeld mirrors the held-postgres bats test: note,
// reconcile, wait and relay run in order and the hook exits 0.
func TestBatsHookPostgresOnHeld(t *testing.T) {
	f := heldFixture(t, "postgres")
	allowKubectl(f)
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-postgres", "get", "pods", "-o", "name"), fexec.Result{Stdout: []byte("pod/postgres-0\n")})
	f.r.On("kubectl", devzoneKubectl("-n", "devzone-postgres", "wait", "--for=condition=Ready", "pod", "--all", "--timeout=300s"), fexec.Result{})
	relayScript := filepath.Join(f.root, ".devcontainer", "postgres", "postgres.sh")
	f.r.On("bash", []string{relayScript, "relay-start"}, fexec.Result{})
	if code := f.run("services-hook", "postgres", "on"); code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	calls := f.r.Calls()
	namespace := callIndex(calls, "kubectl", devzoneKubectl("apply", "-f", "-")...)
	secret := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-postgres", "create", "secret", "generic", "postgres-admin", "--from-file=password="+filepath.Join(f.root, "workspace", ".postgres", "admin-password"))...)
	app := findStdinCall(t, calls, "kubectl", "kind: Application", devzoneKubectl("apply", "-f", "-")...)
	pods := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-postgres", "get", "pods", "-o", "name")...)
	wait := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-postgres", "wait", "--for=condition=Ready", "pod", "--all", "--timeout=300s")...)
	relay := callIndex(calls, "bash", []string{relayScript, "relay-start"}...)
	for name, idx := range map[string]int{"namespace": namespace, "secret": secret, "application": app, "pods": pods, "wait": wait, "relay": relay} {
		if idx < 0 {
			t.Fatalf("%s call missing: %v", name, calls)
		}
	}
	if !(namespace < secret && secret < app && app < pods && pods < wait && wait < relay) {
		t.Fatalf("unexpected hook order: %v", calls)
	}
	if got := newFixtureModule(t, f).conf().Get("services", "postgres"); got != "on" {
		t.Fatalf("services postgres = %q", got)
	}
	if !strings.Contains(f.out.String(), "✔ postgres held by Argo CD") {
		t.Fatalf("out=%q", f.out.String())
	}
}

// TestBatsHookPostgresOnNotHeld mirrors the not-held bats test: exit 3 and no
// command, so the caller keeps the helm-direct path.
func TestBatsHookPostgresOnNotHeld(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	writeTestFile(t, f.state, "argocd=off\n")
	if code := f.run("services-hook", "postgres", "on"); code != 3 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls=%v", f.r.Calls())
	}
}

// TestBatsHookFailingReconcile mirrors the failing-reconcile bats test: no
// wait and no relay after a failed reconcile.
func TestBatsHookFailingReconcile(t *testing.T) {
	f := heldFixture(t, "mysql")
	allowKubectl(f)
	f.r.On("kubectl", devzoneKubectl("apply", "-f", "-"), fexec.Result{Code: 2})
	if code := f.run("services-hook", "mysql", "on"); code != 1 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "kubectl" && (strings.Contains(joinedArgs(call), "get pods") || strings.Contains(joinedArgs(call), "wait")) {
			t.Fatalf("waited after failure: %q", joinedArgs(call))
		}
		if call.Name == "bash" && strings.HasSuffix(joinedArgs(call), "relay-start") {
			t.Fatalf("relay after failure: %q", joinedArgs(call))
		}
	}
}

// TestBatsHookGitlabNotHeld mirrors the GitLab bats test: this hook does not
// hold GitLab, so it exits 3 without calling anything.
func TestBatsHookGitlabNotHeld(t *testing.T) {
	f := newModFixture(t)
	allowKubectl(f)
	if code := f.run("services-hook", "gitlab", "on"); code != 3 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if len(f.r.Calls()) != 0 {
		t.Fatalf("calls=%v", f.r.Calls())
	}
}
