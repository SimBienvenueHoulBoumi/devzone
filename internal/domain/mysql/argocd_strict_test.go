package mysql

import (
	"errors"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// errNoNetwork simulates a repository that cannot be reached by the Runner.
var errNoNetwork = errors.New("network unreachable")

// TestInstallUnknownRevisionFails checks that MySQL does not fall back to a
// direct chart installation when Argo CD is on without a usable revision. The
// recorded calls prove that no data was touched after the failure.
func TestInstallUnknownRevisionFails(t *testing.T) {
	f := newFixture(t)
	f.activeOn("kind-devzone")
	f.contextReady("kind-devzone", "kind-devzone", "kind-devzone")
	f.saveState("mysql=on", "cluster=kind-devzone", "argocd=on")
	f.r.OnError("git", []string{"ls-remote", "--tags", "--refs", "https://github.com/SimBienvenueHoulBoumi/devzone.git"},
		exec.Result{}, errNoNetwork)
	if code := Install(t.Context(), f.opts, nil); code == 0 {
		t.Fatalf("install: code 0, want a failure (output %q)", f.out.String())
	}
	if !strings.Contains(f.errOut.String(), "cannot list the tags") || !strings.Contains(f.errOut.String(), "DEVZONE_ARGOCD_REVISION") {
		t.Fatalf("unclear failure: %q", f.errOut.String())
	}
	for _, call := range f.r.Calls() {
		if call.Name == "helm" || call.Name == "openssl" {
			t.Fatalf("installation continued after the revision failure: %v", f.r.Calls())
		}
		if call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "create secret") {
			t.Fatalf("a secret was created after the revision failure: %v", f.r.Calls())
		}
	}
}
