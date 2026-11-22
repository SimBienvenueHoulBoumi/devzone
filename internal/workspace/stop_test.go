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
func runStop(r Runner, fallbackStatus int) (status int, out, errOut string, fellBack bool) {
	var o, e bytes.Buffer
	status = Stop(r, &o, &e, func() int {
		fellBack = true
		return fallbackStatus
	})
	return status, o.String(), e.String(), fellBack
}

func TestStopUninstallsReleaseWhenArgocdAbsent(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: argocdNamespaceCall, stderr: "Error from server (NotFound)\n", status: 1},
		{match: "uninstall", stdout: "release \"devzone-workspace\" uninstalled\n"},
	}}
	status, out, errOut, fellBack := runStop(r, 9)
	if status != 0 || out != "release \"devzone-workspace\" uninstalled\n" || errOut != "" || fellBack {
		t.Fatalf("status %d, stdout %q, stderr %q, fallback %v", status, out, errOut, fellBack)
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
	status, out, _, _ := runStop(r, 9)
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
	status, _, _, fellBack := runStop(r, 9)
	if status != 0 || fellBack {
		t.Fatalf("status %d, fallback %v: want the helm release removed", status, fellBack)
	}
	wantCalls(t, r.calls, contextsCall, "--context devzone "+argocdNamespaceCall,
		contextsCall, "--context devzone "+argocdApplicationCall,
		contextsCall, helmUninstallCall)
}

func TestStopArgocdHoldsWorkspaceFallsBackBeforeAnyChange(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	writeFile(t, dir+"/relays/5432", "999999\n")
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", stdout: "namespace/devzone-argocd\n"},
		{match: "get application", stdout: "application\n"},
	}}
	status, out, _, fellBack := runStop(r, 7)
	if status != 7 || out != "" || !fellBack {
		t.Fatalf("status %d, stdout %q, fallback %v: want the bash status", status, out, fellBack)
	}
	for _, c := range r.calls {
		if strings.Contains(c, "uninstall") {
			t.Fatalf("helm called although Argo CD holds the workspace: %q", c)
		}
	}
	if !exists(dir + "/relays/5432") {
		t.Fatal("the port state changed before the fallback")
	}
}

func TestStopHelmFailureKeepsStatusAndOutput(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: argocdNamespaceCall, status: 1},
		{match: "uninstall", stderr: "Error: uninstall: release not loaded\n", status: 1},
	}}
	status, out, errOut, _ := runStop(r, 9)
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
	status, _, errOut, _ := runStop(r, 9)
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
	status, out, _, fellBack := runStop(r, 9)
	if status != 0 || out != "uninstalled\n" || fellBack {
		t.Fatalf("status %d, stdout %q, fallback %v", status, out, fellBack)
	}
}
