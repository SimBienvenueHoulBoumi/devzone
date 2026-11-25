package mysql

import (
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// programMounted programs the claim mounted by the StatefulSet.
func (f *fixture) programMounted(claim string) {
	f.on([]string{"get", "statefulset", "mysql", "-o", "jsonpath=" + claimJSONPath},
		exec.Result{Stdout: []byte(claim)})
}

// TestVolumeList checks the PVC listing and the marker on the mounted one.
func TestVolumeList(t *testing.T) {
	f := newFixture(t)
	f.programPVCs("data-mysql-0", "donnees-mysql-0")
	f.programMounted("data")
	if code := Run(nil, f.opts, []string{"volume"}); code != 0 {
		t.Fatalf("volume: code %d", code)
	}
	out := f.out.String()
	if !strings.Contains(out, "data-mysql-0 (mounted)") || !strings.Contains(out, "donnees-mysql-0") ||
		strings.Contains(out, "donnees-mysql-0 (mounted)") {
		t.Fatalf("output = %q", out)
	}
}

// TestVolumeSelect checks that selecting a volume deletes the StatefulSet and
// reapplies the chart on that claim.
func TestVolumeSelect(t *testing.T) {
	f := newFixture(t)
	f.activeOn("host-cluster")
	f.contextReady("host-cluster", "host-cluster", "host-cluster")
	f.rootReady("mdproot")
	f.programChart("data")
	if code := Run(nil, f.opts, []string{"volume", "data"}); code != 0 {
		t.Fatalf("volume data: code %d, stderr %q", code, f.errOut.String())
	}
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", ns, "delete", "statefulset", "mysql", "--ignore-not-found"})
	found := false
	for _, call := range f.r.Calls() {
		if call.Name == "helm" && strings.Contains(strings.Join(call.Args, " "), "--set claim=data") {
			found = true
		}
	}
	if !found {
		t.Fatalf("chart not applied on data: %+v", f.r.Calls())
	}
}

// TestVolumeDeleteRefusal checks that without --yes nor terminal no PVC is
// deleted.
func TestVolumeDeleteRefusal(t *testing.T) {
	f := newFixture(t)
	f.programMounted("data")
	if code := Run(nil, f.opts, []string{"volume", "--delete", "donnees"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "devzone mysql volume --delete donnees --yes") {
		t.Fatalf("volume --delete: code %d, stderr %q", code, f.errOut.String())
	}
	for _, call := range f.r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "delete pvc") {
			t.Fatalf("PVC deleted despite the refusal: %+v", call)
		}
	}
}

// TestVolumeDeleteMounted checks that the mounted volume cannot be deleted.
func TestVolumeDeleteMounted(t *testing.T) {
	f := newFixture(t)
	f.programMounted("data")
	if code := Run(nil, f.opts, []string{"volume", "--delete", "data", "--yes"}); code != 2 ||
		!strings.Contains(f.errOut.String(), "mounted volume, deletion refused") {
		t.Fatalf("volume --delete data: code %d, stderr %q", code, f.errOut.String())
	}
}

// TestVolumeDelete checks the PVC name completion and the deletion message.
func TestVolumeDelete(t *testing.T) {
	f := newFixture(t)
	f.programMounted("data")
	if code := Run(nil, f.opts, []string{"volume", "--delete", "donnees", "--yes"}); code != 0 {
		t.Fatalf("volume --delete: code %d, stderr %q", code, f.errOut.String())
	}
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", ns, "delete", "pvc", "donnees-mysql-0"})
	if f.out.String() != "✔ volume donnees-mysql-0 deleted\n" {
		t.Fatalf("output = %q", f.out.String())
	}
}
