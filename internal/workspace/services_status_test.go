package workspace

import (
	"bytes"
	"errors"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"os"
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
		if strings.Contains(call, "get namespace") && !strings.HasPrefix(call, "--context "+fexec.ContextName()+" ") {
			t.Errorf("call %q: want the services context flag", call)
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

// TestServicesModulesFile checks the .devzone.modules effects of disable and
// enable (#605): postgres=off is written, other lines are kept, an absent
// file is created, a failing installer leaves the file intact.
func TestServicesModulesFile(t *testing.T) {
	write := func(t *testing.T, h *servicesHarness, content string) {
		t.Helper()
		if err := os.WriteFile(h.modules, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Run("gitlab=on written", func(t *testing.T) {
		h := newServicesHarness(t)
		write(t, h, "workspace=kubernetes\nargocd=off\n")
		if status := h.env.Run([]string{"enable", "gitlab"}); status != 0 {
			t.Fatalf("status = %d", status)
		}
		data, err := os.ReadFile(h.modules)
		if err != nil || !strings.Contains(string(data), "gitlab=on\n") {
			t.Fatalf("state = %q, err = %v", data, err)
		}
	})
	t.Run("postgres=off written", func(t *testing.T) {
		h := newServicesHarness(t)
		write(t, h, "workspace=kubernetes\nargocd=off\n")
		if status := h.env.Run([]string{"disable", "postgres"}); status != 0 {
			t.Fatalf("status = %d", status)
		}
		data, err := os.ReadFile(h.modules)
		if err != nil || !strings.Contains(string(data), "postgres=off\n") {
			t.Fatalf("state = %q, err = %v", data, err)
		}
	})
	t.Run("installer failure leaves file intact", func(t *testing.T) {
		h := newServicesHarness(t)
		original := "workspace=kubernetes\nargocd=off\n"
		write(t, h, original)
		h.env.Runner.(*fakeRunner).replies[4] = reply{match: "exec -i", status: 3}
		if status := h.env.Run([]string{"enable", "gitlab"}); status != 3 {
			t.Fatalf("status = %d", status)
		}
		data, err := os.ReadFile(h.modules)
		if err != nil || string(data) != original {
			t.Fatalf("state = %q, err = %v, want %q intact", data, err, original)
		}
	})
	t.Run("other lines kept", func(t *testing.T) {
		h := newServicesHarness(t)
		write(t, h, "workspace=kubernetes\nfoo=bar\nargocd=off\n")
		if status := h.env.Run([]string{"enable", "postgres"}); status != 0 {
			t.Fatalf("status = %d", status)
		}
		data, _ := os.ReadFile(h.modules)
		for _, line := range []string{"postgres=on", "foo=bar", "workspace=kubernetes", "argocd=off"} {
			if !strings.Contains(string(data), line+"\n") {
				t.Fatalf("state = %q, missing line %q", data, line)
			}
		}
	})
	t.Run("absent file created", func(t *testing.T) {
		h := newServicesHarness(t)
		if err := os.Remove(h.modules); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if status := h.env.Run([]string{"disable", "mysql"}); status != 0 {
			t.Fatalf("status = %d", status)
		}
		data, err := os.ReadFile(h.modules)
		if err != nil || string(data) != "mysql=off\n" {
			t.Fatalf("state = %q, err = %v", data, err)
		}
	})
}

// TestServicesSeedAndStatusLeaveModulesFile checks seed and status never
// touch .devzone.modules (#605).
func TestServicesSeedAndStatusLeaveModulesFile(t *testing.T) {
	h := newServicesHarness(t)
	original := "workspace=kubernetes\nargocd=off\n"
	if err := os.WriteFile(h.modules, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}
	if status := h.env.Run([]string{"seed", "gitlab"}); status != 0 {
		t.Fatalf("seed status = %d", status)
	}
	var out bytes.Buffer
	if status := ServicesStatus(h.env.Runner, &out); status != 0 {
		t.Fatalf("status = %d", status)
	}
	data, err := os.ReadFile(h.modules)
	if err != nil || string(data) != original {
		t.Fatalf("state = %q, err = %v, want %q intact", data, err, original)
	}
}

// TestServicesStatusPostgresInstalled checks postgres alone is installed, by
// its namespace, the other services are not.
func TestServicesStatusPostgresInstalled(t *testing.T) {
	r := &fakeRunner{replies: []reply{
		{match: contextsCall, stdout: devzoneContexts},
		{match: "get namespace devzone-postgres", status: 0},
		{match: "get namespace", status: 1},
	}}
	status, out := servicesStatusRun(r)
	if status != 0 {
		t.Fatalf("status %d, want 0", status)
	}
	for _, want := range []string{"✔ postgres installed (namespace devzone-postgres)", "○ gitlab not installed", "○ mysql not installed", "○ argocd not installed"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output %q does not contain %q", out, want)
		}
	}
}
