package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestBatsEnableArgocdInstallOrder mirrors the enable-install bats test: an
// isolated namespace, the wrapper chart, a 600 password file and a relay.
func TestBatsEnableArgocdInstallOrder(t *testing.T) {
	f := newModFixture(t)
	relay := "relay_start argocd devzone devzone-argocd svc/argocd-server 8443:443"
	f.r.On("bash", []string{"-c", relayCmd(f.root, f.state, relay)}, fexec.Result{})
	if code := f.run("install"); code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if !strings.Contains(f.out.String(), "✔ argocd module ready: https://127.0.0.1:8443") {
		t.Fatalf("out=%q", f.out.String())
	}
	if strings.Contains(f.out.String()+f.err.String(), "secret-admin") {
		t.Fatalf("password leaked: %q %q", f.out.String(), f.err.String())
	}
	admin := filepath.Join(f.secrets, "admin.env")
	data, err := os.ReadFile(admin)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(admin)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 || !strings.Contains(string(data), "ARGOCD_PASSWORD=secret-admin\n") {
		t.Fatalf("admin.env=%q mode=%v", data, info.Mode().Perm())
	}
	calls := f.r.Calls()
	chart := filepath.Join(f.root, "charts", "devzone-argocd")
	create := callIndex(calls, "kubectl", mgmtKubectl(f, "create", "namespace", "devzone-argocd", "--dry-run=client", "-o", "yaml")...)
	apply := callIndex(calls, "kubectl", mgmtKubectl(f, "apply", "-f", "-")...)
	label := callIndex(calls, "kubectl", mgmtKubectl(f, "label", "namespace", "devzone-argocd", clusterLabel, "--overwrite")...)
	dep := callIndex(calls, "helm", []string{"dependency", "build", chart}...)
	upgrade := callIndex(calls, "helm", []string{"--kubeconfig", filepath.Join(f.root, "hote.config"), "--kube-context", mgmtContext(f), "upgrade", "--install", "argocd", chart, "--namespace", "devzone-argocd", "--create-namespace", "--timeout", "600s", "--wait"}...)
	secret := callIndex(calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "get", "secret", "argocd-initial-admin-secret", "-o", "jsonpath={.data.password}")...)
	relayIdx := callIndex(calls, "bash", []string{"-c", relayCmd(f.root, f.state, relay)}...)
	for name, idx := range map[string]int{"create": create, "apply": apply, "label": label, "dependency": dep, "upgrade": upgrade, "secret": secret, "relay": relayIdx} {
		if idx < 0 {
			t.Fatalf("%s call missing: %v", name, calls)
		}
	}
	if !(create < apply && apply < label && label < dep && dep < upgrade && upgrade < secret && secret < relayIdx) {
		t.Fatalf("unexpected install order: %v", calls)
	}
	policy := stdinFor(t, calls, "kubectl", devzoneKubectl("-n", "devzone-argocd", "apply", "-f", "-")...)
	if !strings.Contains(policy, "kind: NetworkPolicy") || !strings.Contains(policy, "name: devzone-meme-namespace") {
		t.Fatalf("policy=%q", policy)
	}
	for _, call := range calls {
		if call.Name == "helm" && strings.Contains(joinedArgs(call), "argo/argo-cd") {
			t.Fatalf("upstream chart used: %q", joinedArgs(call))
		}
	}
	if !hasCall(calls, "bash", []string{filepath.Join(f.root, ".devcontainer", "password.sh"), "regenerer"}...) {
		t.Fatalf("credentials not regenerated: %v", calls)
	}
}

// TestBatsArgocdAlreadyInstalled mirrors the already-installed bats test: the
// status asks for the relay and no installation command is run again.
func TestBatsArgocdAlreadyInstalled(t *testing.T) {
	f := heldFixture(t, "argocd")
	if code := f.run("status"); code != 0 || !strings.Contains(f.out.String(), "relay stopped") {
		t.Fatalf("status: code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	f.out.Reset()
	relay := "relay_start argocd devzone devzone-argocd svc/argocd-server 8443:443"
	if code := f.run("relay-start"); code != 0 {
		t.Fatalf("relay-start: code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("reinstalled: %q", joinedArgs(call))
		}
	}
	if !hasCall(f.r.Calls(), "bash", []string{"-c", relayCmd(f.root, f.state, relay)}...) {
		t.Fatalf("relay not restarted: %v", f.r.Calls())
	}
}

// TestBatsArgocdEnglishNamesNoWarning mirrors the English-name bats test: Go
// subcommands emit no deprecation notice on standard error.
func TestBatsArgocdEnglishNamesNoWarning(t *testing.T) {
	f := newModFixture(t)
	for _, args := range [][]string{{"status"}, {"relay-start"}, {"relay-stop"}} {
		f.out.Reset()
		f.err.Reset()
		if code := f.run(args...); code != 0 {
			t.Fatalf("%v: code=%d err=%q", args, code, f.err.String())
		}
		if strings.Contains(f.err.String(), "deprecated") {
			t.Fatalf("%v: stderr=%q", args, f.err.String())
		}
	}
}
