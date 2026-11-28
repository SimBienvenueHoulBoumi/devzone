package workspace

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Joined arguments of the calls of Stop: the Argo CD checks and the helm release
const (
	argocdNamespaceCall   = "get namespace devzone-argocd"
	argocdApplicationCall = "-n devzone-argocd get application.argoproj.io devzone-workspace"
	helmUninstallCurrent  = "helm uninstall devzone-workspace --namespace devzone-workspace"
)

// helmUninstallCall is the helm release removal with the services context flag.
var helmUninstallCall = "helm --kube-context " + fexec.ContextName() + " uninstall devzone-workspace --namespace devzone-workspace"

// noRemove is an AppRemover of a repository that is not designated: nothing to remove.
func noRemove(string) int { return 0 }

// runStop runs Stop on r with a remover that succeeds, and returns the status,
// the standard output and the standard error
func runStop(r Runner) (status int, out, errOut string) {
	var o, e bytes.Buffer
	status = Stop(r, noRemove, &o, &e)
	return status, o.String(), e.String()
}

// recordingRemover returns an AppRemover that records its call in r.calls and
// answers status, as the GitOps removal of the command layer does.
func recordingRemover(r *fakeRunner, status int) AppRemover {
	return func(name string) int {
		r.calls = append(r.calls, "remove "+name)
		return status
	}
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
	wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+" "+argocdNamespaceCall,
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
	wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+" "+argocdNamespaceCall,
		contextsCall, "--context "+fexec.ContextName()+" "+argocdApplicationCall,
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
	if exists(dir + "/relays/5432") {
		t.Fatal("the port state must be cleaned by stopPorts, as the shell did")
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
	wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+" "+argocdNamespaceCall,
		contextsCall, "--context "+fexec.ContextName()+" "+argocdApplicationCall,
		contextsCall, "--context "+fexec.ContextName()+" -n devzone-argocd delete application.argoproj.io devzone-workspace --ignore-not-found --wait=true")
}

// A GitOps repository that refuses the removal of the Application file keeps the
// Application in the cluster: the status is 1 and no delete is sent (the bash
// gitops_delete_application returned 1 before the cluster delete).
func TestStopRefusedRemovalKeepsApplication(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", stdout: "namespace/devzone-argocd\n"},
		{match: "get application", stdout: "application\n"},
		{match: "delete", stdout: "application deleted\n"},
	}}
	var o, e bytes.Buffer
	status := Stop(r, recordingRemover(r, 1), &o, &e)
	if status != 1 {
		t.Fatalf("status %d, want 1 when the repository refuses the removal", status)
	}
	for _, c := range r.calls {
		if strings.Contains(c, "delete") {
			t.Fatalf("Application deleted although its file was kept: %q", c)
		}
	}
}

// The Application file leaves the repository before the Application is deleted
// from the cluster, so that the root Application does not recreate it.
func TestStopRemovesFileBeforeDelete(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", stdout: "namespace/devzone-argocd\n"},
		{match: "get application", stdout: "application\n"},
		{match: "delete", stdout: "application deleted\n"},
	}}
	var o, e bytes.Buffer
	if status := Stop(r, recordingRemover(r, 0), &o, &e); status != 0 {
		t.Fatalf("status %d, stderr %q", status, e.String())
	}
	wantCalls(t, r.calls, contextsCall, "--context "+fexec.ContextName()+" "+argocdNamespaceCall,
		contextsCall, "--context "+fexec.ContextName()+" "+argocdApplicationCall,
		"remove devzone-workspace",
		contextsCall, "--context "+fexec.ContextName()+" -n devzone-argocd delete application.argoproj.io devzone-workspace --ignore-not-found --wait=true")
}
