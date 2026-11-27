package clustermenu

import (
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestRemoteOnlyNonLocalOffered: local contexts (by name) are not offered, the remote one is marked remote
func TestRemoteOnlyNonLocalOffered(t *testing.T) {
	f := newFixture("1\n\n", true)
	f.contexts("docker-desktop", "kind-poste", "prod-eks")
	f.server("prod-eks", "https://203.0.113.5:6443")
	f.menu.Offer()
	if !strings.Contains(f.out.String(), "  1) prod-eks (remote)") {
		t.Fatalf("remote context not offered: %q", f.out.String())
	}
	for _, local := range []string{"docker-desktop (remote)", "kind-poste (remote)"} {
		if strings.Contains(f.out.String(), local) {
			t.Fatalf("local context offered: %q", f.out.String())
		}
	}
}

// TestRemoteLoopbackServerIsLocal: a context whose server is on localhost is not remote
func TestRemoteLoopbackServerIsLocal(t *testing.T) {
	f := newFixture("1\n", true)
	f.contexts("mon-cluster")
	f.server("mon-cluster", "https://127.0.0.1:6443")
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false with only a local context")
	}
	if !strings.Contains(f.errOut.String(), "no remote context in your kubeconfig") {
		t.Fatalf("err = %q", f.errOut.String())
	}
}

// TestRemoteNameTypedRight: the context is selected, the cost warning is shown
func TestRemoteNameTypedRight(t *testing.T) {
	f := newFixture("1\n1\nprod-eks\n", true)
	f.contexts("docker-desktop", "prod-eks")
	f.server("prod-eks", "https://203.0.113.5:6443")
	f.runner.On("kubectl", []string{"config", "use-context", "prod-eks"}, exec.Result{})
	if !f.menu.Offer() {
		t.Fatalf("Offer = false, err = %q", f.errOut.String())
	}
	if !strings.Contains(f.out.String(), "a pod, a volume and the namespace devzone-workspace") {
		t.Fatalf("cost warning missing: %q", f.out.String())
	}
	if !f.calledWith("kubectl", "config", "use-context", "prod-eks") {
		t.Fatal("use-context not called for prod-eks")
	}
	if !strings.Contains(f.out.String(), "✔ current kubectl context: prod-eks") {
		t.Fatalf("out = %q", f.out.String())
	}
}

// TestRemoteWrongNameNothingDone: a name not typed back stops before use-context
func TestRemoteWrongNameNothingDone(t *testing.T) {
	f := newFixture("1\n1\nprod\n", true)
	f.contexts("docker-desktop", "prod-eks")
	f.server("prod-eks", "https://203.0.113.5:6443")
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false when the name is not typed back")
	}
	if !strings.Contains(f.errOut.String(), "name not typed back: nothing done") {
		t.Fatalf("err = %q", f.errOut.String())
	}
	if f.calledWith("kubectl", "config", "use-context", "prod") {
		t.Fatal("use-context called for a name not typed back")
	}
}

// TestRemoteNoRemoteContext: only local contexts in the kubeconfig
func TestRemoteNoRemoteContext(t *testing.T) {
	f := newFixture("1\n", true)
	f.contexts("docker-desktop")
	if f.menu.Offer() {
		t.Fatal("Offer = true, want false")
	}
	want := "✖ no remote context in your kubeconfig: add one with the command of your provider (aws, gcloud, az), then run the same command again\n"
	if f.errOut.String() != want {
		t.Fatalf("err = %q, want %q", f.errOut.String(), want)
	}
}

// TestRemoteBadNumber: a non-number cancels, a number out of the list says so
func TestRemoteBadNumber(t *testing.T) {
	f := newFixture("1\nx\n", true)
	f.contexts("prod-eks")
	f.server("prod-eks", "https://203.0.113.5:6443")
	f.menu.Offer()
	if f.errOut.String() != "✖ cancelled\n" {
		t.Fatalf("err = %q, want cancelled", f.errOut.String())
	}
	g := newFixture("1\n9\n", true)
	g.contexts("prod-eks")
	g.server("prod-eks", "https://203.0.113.5:6443")
	g.menu.Offer()
	if g.errOut.String() != "✖ no such cluster: 9\n" {
		t.Fatalf("err = %q, want no such cluster", g.errOut.String())
	}
}
