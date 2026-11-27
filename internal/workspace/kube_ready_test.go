package workspace

import (
	"errors"
	"testing"
)

// kubeLookup finds only the named programs, so a test never asks the real PATH
// whether kubectl or helm is installed.
func kubeLookup(names ...string) func(string) (string, error) {
	return func(name string) (string, error) {
		for _, n := range names {
			if n == name {
				return "/fake/" + name, nil
			}
		}
		return "", errors.New(name + " not found")
	}
}

// kubeReadyTest runs the check with a fake runner and lookup, returning the
// reason, the readiness and the recorded calls.
func kubeReadyTest(r *fakeRunner, lookup func(string) (string, error), hint bool) (string, bool, []string) {
	reason, ready := kubeEnv{runner: r, lookPath: lookup}.ready(hint)
	return reason, ready, r.calls
}

// TestKubeReadyDevzoneContext checks that a declared devzone context is the one
// probed and that a ready cluster has no reason to print.
func TestKubeReadyDevzoneContext(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: "get-contexts", stdout: "devzone\n"},
		{match: "cluster-info"},
	}}
	reason, ready, calls := kubeReadyTest(r, kubeLookup("kubectl", "helm"), false)
	if !ready || reason != "" {
		t.Fatalf("reason = %q, ready = %v; want ready with no reason", reason, ready)
	}
	if len(calls) != 2 || calls[1] != "cluster-info --request-timeout=5s --context devzone" {
		t.Fatalf("calls = %q", calls)
	}
}

// TestKubeReadyCurrentContext checks that, without a devzone context, the
// current context is probed with no context flag.
func TestKubeReadyCurrentContext(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: "get-contexts", stdout: "lab\n"},
		{match: "cluster-info"},
	}}
	reason, ready, calls := kubeReadyTest(r, kubeLookup("kubectl", "helm"), false)
	if !ready || reason != "" {
		t.Fatalf("reason = %q, ready = %v; want ready with no reason", reason, ready)
	}
	for _, call := range calls {
		if call == "cluster-info --request-timeout=5s --context devzone" {
			t.Fatalf("call %q must not force the devzone context", call)
		}
	}
}

// TestKubeReadyMissingPrograms checks that a missing program is reported before
// the cluster is probed.
func TestKubeReadyMissingPrograms(t *testing.T) {
	for _, tc := range []struct {
		name string
		have []string
		want string
	}{
		{"kubectl", []string{"helm"}, "kubectl missing"},
		{"helm", []string{"kubectl"}, "helm missing"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &fakeRunner{}
			reason, ready, calls := kubeReadyTest(r, kubeLookup(tc.have...), false)
			if ready || reason != tc.want {
				t.Fatalf("reason = %q, ready = %v; want %q and not ready", reason, ready, tc.want)
			}
			if len(calls) != 0 {
				t.Fatalf("calls = %q; want none", calls)
			}
		})
	}
}

// TestKubeReadyShortReason checks the one-line reason used by creation: no
// other program is probed and the server of the context is named.
func TestKubeReadyShortReason(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: "get-contexts", stdout: "devzone\n"},
		{match: "cluster-info", status: 1},
		{match: "clusters[0].cluster.server", stdout: "https://127.0.0.1:6443\n"},
	}}
	reason, ready, calls := kubeReadyTest(r, kubeLookup("kubectl", "helm"), false)
	want := "cluster devzone unreachable (https://127.0.0.1:6443)"
	if ready || reason != want {
		t.Fatalf("reason = %q, ready = %v; want %q and not ready", reason, ready, want)
	}
	if len(calls) != 3 {
		t.Fatalf("calls = %q; want the probe and two context reads", calls)
	}
}

// TestKubeReadyShortReasonCurrentContext checks that the current context is
// named when there is no devzone one.
func TestKubeReadyShortReasonCurrentContext(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: "get-contexts", stdout: "lab\n"},
		{match: "cluster-info", status: 1},
		{match: "current-context", stdout: "kind-poste\n"},
		{match: "clusters[0].cluster.server", stdout: "https://127.0.0.1:6443\n"},
	}}
	reason, ready, _ := kubeReadyTest(r, kubeLookup("kubectl", "helm"), false)
	want := "cluster kind-poste unreachable (https://127.0.0.1:6443)"
	if ready || reason != want {
		t.Fatalf("reason = %q, ready = %v; want %q and not ready", reason, ready, want)
	}
}

// TestKubeReadyHint checks the user message: the ✖ line and the check command,
// with no machine-specific wording and no extra probe.
func TestKubeReadyHint(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: "get-contexts", stdout: "devzone\n"},
		{match: "cluster-info", status: 1},
		{match: "clusters[0].cluster.server", stdout: "https://127.0.0.1:6443\n"},
	}}
	reason, ready, calls := kubeReadyTest(r, kubeLookup("kubectl", "helm"), true)
	want := "✖ Kubernetes cluster devzone unreachable (https://127.0.0.1:6443)\n  Check the contexts: kubectl config get-contexts"
	if ready || reason != want {
		t.Fatalf("reason = %q, ready = %v; want %q and not ready", reason, ready, want)
	}
	if len(calls) != 3 {
		t.Fatalf("calls = %q; want no probe beyond the check", calls)
	}
}

// TestKubeReadyHintMissingProgram checks that the ✖ line is also used when a
// program is missing.
func TestKubeReadyHintMissingProgram(t *testing.T) {
	r := &fakeRunner{}
	reason, ready, _ := kubeReadyTest(r, kubeLookup("helm"), true)
	if ready || reason != "✖ kubectl missing" {
		t.Fatalf("reason = %q, ready = %v", reason, ready)
	}
}

// TestKubeReadyUnknownServer checks the fallback when the server cannot be
// read from the kubeconfig.
func TestKubeReadyUnknownServer(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: "get-contexts", stdout: "devzone\n"},
		{match: "cluster-info", status: 1},
	}}
	reason, ready, _ := kubeReadyTest(r, kubeLookup("kubectl", "helm"), false)
	want := "cluster devzone unreachable (unknown server)"
	if ready || reason != want {
		t.Fatalf("reason = %q, ready = %v; want %q and not ready", reason, ready, want)
	}
}
