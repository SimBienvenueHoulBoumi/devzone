package mysql

import (
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestClaimNone checks that without a PVC the claim is "donnees", with the
// kubectl call on the devzone context as in the original volume.sh.
func TestClaimNone(t *testing.T) {
	f := newFixture(t)
	f.on([]string{"get", "pvc", "-o", "jsonpath=" + volumeJSONPath}, exec.Result{})
	if code := Run(nil, f.opts, []string{"claim", "devzone-mysql"}); code != 0 {
		t.Fatalf("claim: code %d, stderr %q", code, f.errOut.String())
	}
	if f.out.String() != "donnees\n" {
		t.Fatalf("output = %q", f.out.String())
	}
	assertCall(t, f.r.Calls(), "kubectl", []string{"--context", "devzone", "-n", "devzone-mysql",
		"get", "pvc", "-o", "jsonpath=" + volumeJSONPath})
}

// TestClaimOne checks that the prefix of the single existing PVC is reused.
func TestClaimOne(t *testing.T) {
	f := newFixture(t)
	f.programPVCs("data-mysql-0")
	if code := Run(nil, f.opts, []string{"claim", "devzone-mysql"}); code != 0 {
		t.Fatalf("claim: code %d, stderr %q", code, f.errOut.String())
	}
	if f.out.String() != "data\n" {
		t.Fatalf("output = %q", f.out.String())
	}
}

// TestClaimSeveral checks the three exact refusal lines on stderr and code 2.
func TestClaimSeveral(t *testing.T) {
	f := newFixture(t)
	f.programPVCs("data-mysql-0", "donnees-mysql-0")
	if code := Run(nil, f.opts, []string{"claim", "devzone-mysql"}); code != 2 {
		t.Fatalf("claim: code %d, want 2", code)
	}
	want := "devzone : catalog mysql : several volumes found:\n" +
		"  data-mysql-0\n  donnees-mysql-0\n" +
		"devzone : catalog mysql : choose one with devzone mysql volume <name>\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", f.errOut.String(), want)
	}
	if strings.TrimSpace(f.out.String()) != "" {
		t.Fatalf("stdout = %q", f.out.String())
	}
}
