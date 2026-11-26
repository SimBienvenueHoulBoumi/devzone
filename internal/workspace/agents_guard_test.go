package workspace

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// TestAgentsGuardSuccess checks that a successful guard writes the one line
// and calls kubectl exec with the unchanged pod command.
func TestAgentsGuardSuccess(t *testing.T) {
	r := &fakeRunner{replies: []reply{{match: "exec", status: 0}}}
	var out bytes.Buffer
	AgentsGuard(r, &out)
	if out.String() != "✔ repowarden guard active for the agents of the pod\n" {
		t.Fatalf("out = %q", out.String())
	}
	if len(r.calls) != 2 || !strings.Contains(r.calls[1],
		"exec devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash -lc devzone is-enabled ai && repowarden agents init --global") {
		t.Fatalf("calls = %q", r.calls)
	}
	if r.stdins[1] != "" {
		t.Fatalf("stdin = %q, want nothing sent to the pod", r.stdins[1])
	}
}

// TestAgentsGuardFailures checks that a refused or unreachable kubectl is
// silent, so the workspace start keeps going in every case.
func TestAgentsGuardFailures(t *testing.T) {
	for _, tc := range []struct {
		name  string
		reply reply
	}{
		{"refused", reply{match: "exec", status: 1}},
		{"unreachable", reply{match: "exec", err: errors.New("kubectl cannot start")}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &fakeRunner{replies: []reply{tc.reply}}
			var out bytes.Buffer
			AgentsGuard(r, &out)
			if out.Len() != 0 {
				t.Fatalf("out = %q, want nothing", out.String())
			}
		})
	}
}
