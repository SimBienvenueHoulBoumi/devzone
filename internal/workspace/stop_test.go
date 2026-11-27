package workspace

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// Joined arguments of the calls of Stop: the Argo CD checks and the helm release
const (
	argocdNamespaceCall   = "get namespace devzone-argocd"
	argocdApplicationCall = "-n devzone-argocd get application.argoproj.io devzone-workspace"
	helmUninstallCall     = "helm --kube-context devzone uninstall devzone-workspace --namespace devzone-workspace"
	helmUninstallCurrent  = "helm uninstall devzone-workspace --namespace devzone-workspace"
)

// runStop runs Stop on r with a fallback that records its call and returns fallbackStatus,
// and returns the status, the standard output, the standard error and whether the fallback ran
func runStop(r Runner) (status int, out, errOut string) {
	var o, e bytes.Buffer
	status = Stop(r, &o, &e)
	return status, o.String(), e.String()
}

func TestStopUninstallsReleaseWhenArgocdAbsent(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: argocdNamespaceCall, stderr: "Error from server (NotFound)\n", status: 1},
		{match: "uninstall", stdout: "release \"devzone-workspace\" uninstalled\n"},
	}}
	status, out, errOut := runStop(r)
	if status != 0 || out != "release \"devzone-workspace\" uninstalled\n" || errOut != "" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
	wantCalls(t, r.calls, contextsCall, "--context devzone "+argocdNamespaceCall,
		contextsCall, helmUninstallCall)
}

func TestStopUninstallsWithCurrentContextWhenDevzoneMissing(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: argocdNamespaceCall, status: 1},
		{match: "uninstall", stdout: "uninstalled\n"},
	}}
	status, out, _ := runStop(r)
	if status != 0 || out != "uninstalled\n" {
		t.Fatalf("status %d, stdout %q", status, out)
	}
	wantCalls(t, r.calls, contextsCall, argocdNamespaceCall,
		contextsCall, helmUninstallCurrent)
}

func TestStopNamespaceWithoutApplicationUninstalls(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", stdout: "namespace/devzone-argocd\n"},
		{match: "get application", stderr: "NotFound\n", status: 1},
		{match: "uninstall", stdout: "uninstalled\n"},
	}}
	status, _, _ := runStop(r)
	if status != 0 {
		t.Fatalf("status %d: want the helm release removed", status)
	}
	wantCalls(t, r.calls, contextsCall, "--context devzone "+argocdNamespaceCall,
		contextsCall, "--context devzone "+argocdApplicationCall,
		contextsCall, helmUninstallCall)
}

func TestStopArgocdHoldsWorkspaceDeletesApplication(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	writeFile(t, dir+"/relays/5432", "999999\n")
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", stdout: "namespace/devzone-argocd\n"},
		{match: "get application", stdout: "application\n"},
		{match: "delete", stdout: "application deleted\n"},
	}}
	status, out, _ := runStop(r)
	if status != 0 || !strings.Contains(out, "Application devzone-workspace deleted") {
		t.Fatalf("status %d, stdout %q: want the Application deleted", status, out)
	}
	for _, c := range r.calls {
		if strings.Contains(c, "uninstall") {
			t.Fatalf("helm called although Argo CD holds the workspace: %q", c)
		}
	}
	if !exists(dir + "/relays/5432") {
		t.Fatal("the port state changed")
	}
}

func TestStopHelmFailureKeepsStatusAndOutput(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: argocdNamespaceCall, status: 1},
		{match: "uninstall", stderr: "Error: uninstall: release not loaded\n", status: 1},
	}}
	status, out, errOut := runStop(r)
	if status != 1 || out != "" || errOut != "Error: uninstall: release not loaded\n" {
		t.Fatalf("status %d, stdout %q, stderr %q", status, out, errOut)
	}
}

func TestStopHelmNotStarted(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: argocdNamespaceCall, status: 1},
		{match: "uninstall", err: errors.New("exec: helm not found")},
	}}
	status, _, errOut := runStop(r)
	if status != 127 || !strings.Contains(errOut, "cannot start helm") {
		t.Fatalf("status %d, stderr %q: want 127 and a message", status, errOut)
	}
}

func TestStopKubectlNotStartedUninstalls(t *testing.T) {
	// Without kubectl the Argo CD check fails: the release is then uninstalled through helm
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, err: errors.New("exec: kubectl not found")},
		{match: "uninstall", stdout: "uninstalled\n"},
	}}
	status, out, _ := runStop(r)
	if status != 0 || out != "uninstalled\n" {
		t.Fatalf("status %d, stdout %q", status, out)
	}
}

// Replaces the parity case of manage/test/go-parity.bats (Argo CD holds the
// workspace): the bash entry point only delegates now, so the behaviour is
// pinned here. The folder is empty: no GitOps repository (.argocd.conf) is read.
func TestStopArgocdHoldsWorkspaceExactCallsAndOutput(t *testing.T) {
	t.Chdir(t.TempDir())
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", t.TempDir())
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", stdout: "namespace/devzone-argocd\n"},
		{match: "get application", stdout: "application\n"},
		{match: "delete", stdout: "application.argoproj.io \"devzone-workspace\" deleted\n"},
	}}
	status, out, errOut := runStop(r)
	if status != 0 || errOut != "" {
		t.Fatalf("status %d, stderr %q", status, errOut)
	}
	wantOut := "▶ Application devzone-workspace deleted (Argo CD removes the pod, the volumes stay)…\n" +
		"application.argoproj.io \"devzone-workspace\" deleted\n"
	if out != wantOut {
		t.Fatalf("stdout = %q, want %q", out, wantOut)
	}
	wantCalls(t, r.calls, contextsCall, "--context devzone "+argocdNamespaceCall,
		contextsCall, "--context devzone "+argocdApplicationCall,
		contextsCall, "--context devzone -n devzone-argocd delete application.argoproj.io devzone-workspace --ignore-not-found --wait=true")
}
