package podcmd

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestChangeModuleWithoutName checks the message and status of enable with no module.
func TestChangeModuleWithoutName(t *testing.T) {
	f := newModuleFixture(t)
	if code := f.m.changeModule("on", "", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	want := "devzone : unknown module : (none) ; modules : ai kubernetes gitlab postgres argocd mysql\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", f.errOut.String(), want)
	}
}

// TestChangeModuleUnknown checks that an unknown module is refused without any change.
func TestChangeModuleUnknown(t *testing.T) {
	f := newModuleFixture(t, "ai=off")
	if code := f.m.changeModule("on", "nope", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.errOut.String(), "devzone : unknown module : nope") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	if f.state(t) != "ai=off\n" {
		t.Fatalf("state changed: %q", f.state(t))
	}
}

// TestChangeModuleLLMRemoved checks the migration of the removed llm module:
// its line leaves the state, the notice is printed and the status is 1.
func TestChangeModuleLLMRemoved(t *testing.T) {
	f := newModuleFixture(t, "ai=on", "llm=on")
	if code := f.m.changeModule("on", "llm", nil); code != 1 {
		t.Fatalf("code %d, want 1", code)
	}
	if !strings.Contains(f.out.String(), "llm module removed") {
		t.Fatalf("stdout = %q", f.out.String())
	}
	if strings.Contains(f.state(t), "llm=") {
		t.Fatalf("llm line kept: %q", f.state(t))
	}
}

// TestChangeModuleInPodRefused checks that a service of the pod is not installed
// from the pod: the workstation command is printed, the state does not change.
func TestChangeModuleInPodRefused(t *testing.T) {
	f := newModuleFixture(t, "gitlab=off")
	f.m.inPod = true
	if code := f.m.changeModule("on", "gitlab", nil); code != 2 {
		t.Fatalf("code %d, want 2", code)
	}
	want := "devzone: in the workspace pod, gitlab is installed from the workstation: devzone workspace services enable gitlab\n"
	if f.errOut.String() != want {
		t.Fatalf("stderr = %q, want %q", f.errOut.String(), want)
	}
	if f.state(t) != "gitlab=off\n" || len(f.pod.calls) != 0 {
		t.Fatalf("state %q, calls %v", f.state(t), f.pod.calls)
	}
}

// TestChangeModuleInPodAdminAllowed checks that the services-admin run (DEVZONE_SERVICES_ADMIN)
// installs the service from the pod.
func TestChangeModuleInPodAdminAllowed(t *testing.T) {
	f := newModuleFixture(t, "gitlab=off")
	f.m.inPod, f.m.servicesAdmin = true, true
	f.pod.codes["gitlab status"] = 0
	f.pod.outs["gitlab status"] = "not ready\n"
	if code := f.m.changeModule("on", "gitlab", nil); code != 0 {
		t.Fatalf("code %d, want 0; stderr %q", code, f.errOut.String())
	}
	if !f.pod.has("gitlab install") {
		t.Fatalf("installer not run: %v", f.pod.calls)
	}
}

// TestHookExitStatuses checks the exit status of the Argo CD hook: 0 ends the
// change, 3 falls back to the direct installer, any other status fails.
func TestHookExitStatuses(t *testing.T) {
	f := newModuleFixture(t, "mysql=off", "cluster=kind-devzone")
	f.pod.codes["argocd services-hook mysql on"] = 0
	if code := f.m.changeModule("on", "mysql", nil); code != 0 || f.pod.has("mysql install") {
		t.Fatalf("hook 0: code %d, calls %v", code, f.pod.calls)
	}

	f = newModuleFixture(t, "mysql=off", "cluster=kind-devzone")
	f.pod.codes["argocd services-hook mysql on"] = 1
	if code := f.m.changeModule("on", "mysql", nil); code != 1 {
		t.Fatalf("hook 1: code %d, want 1", code)
	}

	f = newModuleFixture(t, "mysql=off", "cluster=kind-devzone")
	f.pod.codes["argocd services-hook mysql on"] = 3
	f.pod.outs["mysql status"] = "ready on kind-devzone\n"
	if code := f.m.changeModule("on", "mysql", nil); code != 0 {
		t.Fatalf("hook 3: code %d", code)
	}
	if !strings.Contains(f.out.String(), "devzone : mysql already active, nothing to do.") {
		t.Fatalf("stdout = %q", f.out.String())
	}
}

// TestChangeModuleAIAndCatalog checks the assistants (ai apply) and a catalog
// application, written then applied with catalog apply.
func TestChangeModuleAIAndCatalog(t *testing.T) {
	f := newModuleFixture(t, "ai=off")
	if code := f.m.changeModule("on", "ai", []string{"--x"}); code != 0 {
		t.Fatalf("ai: code %d", code)
	}
	if !f.pod.has("ai apply on --x") || !strings.Contains(f.state(t), "ai=on") {
		t.Fatalf("ai: calls %v, state %q", f.pod.calls, f.state(t))
	}

	app := filepath.Join(f.root, "catalog", "beam")
	if err := os.MkdirAll(app, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(app, "app.conf"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := f.m.changeModule("on", "beam", nil); code != 0 {
		t.Fatalf("catalog: code %d", code)
	}
	if !f.pod.has("catalog apply") || !strings.Contains(f.state(t), "beam=on") {
		t.Fatalf("catalog: calls %v, state %q", f.pod.calls, f.state(t))
	}
}

// TestRunIsEnabledStatus checks the exit status of is-enabled: 0 when on, 1 when off, 2 when unknown.
func TestRunIsEnabledStatus(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	etat := filepath.Join(root, ".devzone.modules")
	t.Setenv("DEVZONE_STATE", etat)
	if err := os.WriteFile(etat, []byte("ai=on\nmysql=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var errOut bytes.Buffer
	ctx := func(args ...string) *cli.Context {
		return &cli.Context{Args: args, Out: io.Discard, Err: &errOut, Stdin: strings.NewReader(""), Runner: fake.New()}
	}
	if code := runIsEnabled(ctx("ai")); code != 0 {
		t.Fatalf("ai: code %d, want 0", code)
	}
	if code := runIsEnabled(ctx("mysql")); code != 1 {
		t.Fatalf("mysql: code %d, want 1", code)
	}
	if code := runIsEnabled(ctx("nope")); code != 2 {
		t.Fatalf("nope: code %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), "devzone : unknown module : nope") {
		t.Fatalf("stderr = %q", errOut.String())
	}
}
