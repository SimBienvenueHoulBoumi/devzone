package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestApplyArgocdRelayAndInstall checks the relay restart, the already-active
// message and the installer of argocd.
func TestApplyArgocdRelayAndInstall(t *testing.T) {
	f := newModuleFixture(t, "argocd=on")
	f.pod.outs["argocd status"] = "ready, relay stopped\n"
	if code := f.m.applyArgocd("on"); code != 0 || !f.pod.has("argocd relay-start") {
		t.Fatalf("relay: code %d, calls %v", code, f.pod.calls)
	}

	f = newModuleFixture(t, "argocd=on")
	f.pod.outs["argocd status"] = "absent\n"
	f.pod.codes["argocd install"] = 1
	if code := f.m.applyArgocd("on"); code != 1 || f.marker("argocd") != "argocd\n" {
		t.Fatalf("install: code %d, marker %q", code, f.marker("argocd"))
	}
}

// TestApplyKubernetesOff checks that the host kubeconfig is removed and
// metrics-server with it.
func TestApplyKubernetesOff(t *testing.T) {
	f := newModuleFixture(t)
	kube := filepath.Join(f.m.home, ".kube", "hote.config")
	if err := os.MkdirAll(filepath.Dir(kube), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(kube, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code := f.m.applyKubernetes("off"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if _, err := os.Stat(kube); !os.IsNotExist(err) {
		t.Fatalf("kubeconfig kept: %v", err)
	}
	if !f.pod.has("metrics remove") || !strings.Contains(f.out.String(), "devzone : kubernetes disabled") {
		t.Fatalf("calls %v, stdout %q", f.pod.calls, f.out.String())
	}
}

// TestApplyServiceInPod checks that apply does nothing for a service in the pod
// and clears the marker of an earlier start.
func TestApplyServiceInPod(t *testing.T) {
	f := newModuleFixture(t)
	f.m.inPod = true
	f.m.setMarker("gitlab")
	if code := f.m.applyService("gitlab"); code != 0 {
		t.Fatalf("code %d", code)
	}
	if f.marker("gitlab") != "" || len(f.pod.calls) != 0 {
		t.Fatalf("marker %q, calls %v", f.marker("gitlab"), f.pod.calls)
	}
	if !strings.Contains(f.out.String(), "gitlab is installed from the workstation") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestApplyRunsEnabledModules checks the order of devzone apply: the migration,
// the state confirmation, the repository check, then each module that is on.
func TestApplyRunsEnabledModules(t *testing.T) {
	f := newModuleFixture(t, "ai=on", "gitlab=off", "postgres=off", "mysql=off", "argocd=off")
	if code := f.m.apply(); code != 0 {
		t.Fatalf("code %d", code)
	}
	want := "state recovery-confirm|apply-repowarden|ai apply on"
	if strings.Join(f.pod.calls, "|") != want {
		t.Fatalf("calls = %v, want %s", f.pod.calls, want)
	}
}

// TestApplyStopsOnFailure checks that devzone apply stops at the first failing step.
func TestApplyStopsOnFailure(t *testing.T) {
	f := newModuleFixture(t, "ai=on", "gitlab=on")
	f.pod.codes["ai apply on"] = 4
	if code := f.m.apply(); code != 4 {
		t.Fatalf("code %d, want 4", code)
	}
	if f.pod.has("gitlab status") {
		t.Fatalf("gitlab reached after the failure: %v", f.pod.calls)
	}
}
