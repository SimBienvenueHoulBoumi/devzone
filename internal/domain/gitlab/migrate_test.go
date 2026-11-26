package gitlab

import (
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// programKindClusters programs the answer of kindClusters.
func (f *fixture) programKindClusters(names string) {
	f.r.On("kind", []string{"get", "clusters"}, exec.Result{Stdout: []byte(names)})
}

// TestMigrateWithoutConfirmation checks gitlab-cluster.bats "gitlab migrate :
// without confirmation, old kind-gitlab cluster kept" (the installation in
// the services cluster took place before the question).
func TestMigrateWithoutConfirmation(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.programKindClusters("gitlab\n")
	if code := f.run("migrate"); code != 2 {
		t.Fatalf("code = %d, want 2", code)
	}
	if !strings.Contains(f.errStr(), "confirmation impossible without a terminal") {
		t.Errorf("stderr = %q", f.errStr())
	}
	if f.hasCall("kind delete") {
		t.Errorf("kind delete called: %v", f.calls())
	}
	if !f.hasCall("upgrade --install gitlab") {
		t.Errorf("no upgrade --install in calls: %v", f.calls())
	}
}

// TestMigrateYes checks gitlab-cluster.bats "gitlab migrate --yes : installs,
// redoes the seed, then deletes kind-gitlab".
func TestMigrateYes(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.programKindClusters("gitlab\n")
	if code := f.run("migrate", "--yes"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("kind delete cluster --name gitlab") {
		t.Errorf("no kind delete in calls: %v", f.calls())
	}
	if !f.hasCall("config delete-context kind-gitlab") {
		t.Errorf("no config delete-context in calls: %v", f.calls())
	}
	if !f.hasCall("upgrade --install gitlab") {
		t.Errorf("no upgrade --install in calls: %v", f.calls())
	}
}

// TestMigrateNoOldCluster checks the message without the old cluster.
func TestMigrateNoOldCluster(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.programKindClusters("")
	if code := f.run("migrate"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !strings.Contains(f.outStr(), "✔ No old cluster kind-gitlab to delete.") {
		t.Errorf("output = %q", f.outStr())
	}
}

// TestMigrateUnknownArgument checks the refusal of an unknown argument.
func TestMigrateUnknownArgument(t *testing.T) {
	f := newFixture(t)
	if code := f.run("migrate", "--nope"); code != 2 {
		t.Fatalf("code = %d, want 2", code)
	}
	if !strings.Contains(f.errStr(), "devzone : gitlab migrate : unknown argument : --nope") {
		t.Errorf("stderr = %q", f.errStr())
	}
}
