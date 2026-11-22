package workspace

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// servicesStatusRun runs ServicesStatus on r and returns its status and stdout
func servicesStatusRun(r Runner) (int, string) {
	var out bytes.Buffer
	status := ServicesStatus(r, &out)
	return status, out.String()
}

// allInstalledOut and noneInstalledOut are the outputs of ServicesStatus when
// the four services are installed or none is
const (
	allInstalledOut = "  ✔ gitlab installed (namespace devzone-gitlab): devzone workspace services disable gitlab\n" +
		"  ✔ postgres installed (namespace devzone-postgres): devzone workspace services disable postgres\n" +
		"  ✔ mysql installed (namespace devzone-mysql): devzone workspace services disable mysql\n" +
		"  ✔ argocd installed (namespace devzone-argocd): devzone workspace services disable argocd\n"
	noneInstalledOut = "  ○ gitlab not installed: devzone workspace services enable gitlab\n" +
		"  ○ postgres not installed: devzone workspace services enable postgres\n" +
		"  ○ mysql not installed: devzone workspace services enable mysql\n" +
		"  ○ argocd not installed: devzone workspace services enable argocd\n"
)

func TestServicesStatusAllInstalled(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace devzone-gitlab", status: 0},
		{match: "get namespace devzone-postgres", status: 0},
		{match: "get namespace devzone-mysql", status: 0},
		{match: "get namespace devzone-argocd", status: 0},
	}}
	status, out := servicesStatusRun(r)
	if status != 0 || out != allInstalledOut {
		t.Fatalf("status %d, stdout %q, want %q", status, out, allInstalledOut)
	}
}

func TestServicesStatusNoneInstalled(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace devzone-gitlab", status: 1},
		{match: "get namespace devzone-postgres", status: 1},
		{match: "get namespace devzone-mysql", status: 1},
		{match: "get namespace devzone-argocd", status: 1},
	}}
	status, out := servicesStatusRun(r)
	if status != 0 || out != noneInstalledOut {
		t.Fatalf("status %d, stdout %q, want %q", status, out, noneInstalledOut)
	}
}

func TestServicesStatusOneInstalled(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace devzone-gitlab", status: 1},
		{match: "get namespace devzone-postgres", status: 1},
		{match: "get namespace devzone-mysql", status: 1},
		{match: "get namespace devzone-argocd", status: 0},
	}}
	status, out := servicesStatusRun(r)
	want := "  ○ gitlab not installed: devzone workspace services enable gitlab\n" +
		"  ○ postgres not installed: devzone workspace services enable postgres\n" +
		"  ○ mysql not installed: devzone workspace services enable mysql\n" +
		"  ✔ argocd installed (namespace devzone-argocd): devzone workspace services disable argocd\n"
	if status != 0 || out != want {
		t.Fatalf("status %d, stdout %q, want %q", status, out, want)
	}
}

func TestServicesStatusOrder(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", status: 0},
	}}
	status, out := servicesStatusRun(r)
	if status != 0 {
		t.Fatalf("status %d, want 0", status)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != 4 {
		t.Fatalf("stdout %q: want the four lines", out)
	}
	for i, name := range []string{"gitlab", "postgres", "mysql", "argocd"} {
		if prefix := "  ✔ " + name + " installed"; !strings.HasPrefix(lines[i], prefix) {
			t.Fatalf("line %d = %q, want the line of %s first", i, lines[i], name)
		}
	}
}

func TestServicesStatusContextFlag(t *testing.T) {
	// The devzone context is declared: every call of the status carries the
	// flag.
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace", status: 0},
	}}
	if status, _ := servicesStatusRun(r); status != 0 {
		t.Fatalf("status %d, want 0", status)
	}
	for _, call := range r.calls {
		if strings.Contains(call, "get namespace") && !strings.HasPrefix(call, "--context devzone ") {
			t.Errorf("call %q: want the --context devzone flag", call)
		}
	}
	// The devzone context is not declared: the calls carry no flag.
	r = &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: currentContext},
		{match: "get namespace", status: 0},
	}}
	if status, _ := servicesStatusRun(r); status != 0 {
		t.Fatalf("status %d, want 0", status)
	}
	for _, call := range r.calls {
		if strings.Contains(call, "get namespace") && strings.Contains(call, "--context") {
			t.Errorf("call %q: want no context flag", call)
		}
	}
}

func TestServicesStatusKubectlNotStarted(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, err: errors.New("exec: kubectl not found")},
		{match: "get namespace", err: errors.New("exec: kubectl not found")},
	}}
	status, out := servicesStatusRun(r)
	if status != 0 || out != noneInstalledOut {
		t.Fatalf("status %d, stdout %q, want %q", status, out, noneInstalledOut)
	}
}
