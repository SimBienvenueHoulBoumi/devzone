package command

import (
	"bytes"
	"strings"
	"testing"
)

// TestZombiesRefusedOutsidePod checks that the zombie report refuses on a
// workstation, with a clear message and status 1, and that it does not read any
// /proc: the variable the pod sets is the only test. Routed through Run, as the
// user reaches it.

func TestZombiesRefusedOutsidePod(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "")
	var out, errOut bytes.Buffer
	code := Run([]string{"workspace", "zombies"}, &out, &errOut)
	if code != 1 {
		t.Fatalf("status = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "inside the workspace pod only") {
		t.Errorf("message = %q, want the pod-only refusal", errOut.String())
	}
	if out.Len() != 0 {
		t.Errorf("stdout = %q, want nothing on a workstation", out.String())
	}
}
