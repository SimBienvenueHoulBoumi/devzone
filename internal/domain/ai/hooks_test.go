package ai

import (
	"os"
	"strings"
	"testing"
)

// writeSettingsFile puts a settings document in the disposable home.
func writeSettingsFile(t *testing.T, f fixture, data string) {
	t.Helper()
	path := settingsFile(f.o.home())
	os.MkdirAll(path[:strings.LastIndex(path, "/")], 0o755)
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestGuardHooksIdempotent checks that installing twice keeps one guard entry.
func TestGuardHooksIdempotent(t *testing.T) {
	f := withCode(t, newFixture(t))
	if err := InstallGuardHooks(f.o); err != nil {
		t.Fatal(err)
	}
	if err := InstallGuardHooks(f.o); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(settingsFile(f.o.home()))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(data), "--format claude") != 1 {
		t.Fatalf("settings = %q", data)
	}
}

// TestGuardHooksPreserveOtherSettings checks that user keys and hooks survive.
func TestGuardHooksPreserveOtherSettings(t *testing.T) {
	f := withCode(t, newFixture(t))
	writeSettingsFile(t, f, `{"model":"x/y","env":{"AUTRE":"valeur","KUBECONFIG":"ancien"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"outil-personnel"}]}]}}`)
	if err := InstallGuardHooks(f.o); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(settingsFile(f.o.home()))
	for _, want := range []string{"x/y", "valeur", "outil-personnel"} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("settings = %q, want %q", data, want)
		}
	}
	if !strings.Contains(string(data), f.o.home()+"/.kube/agent.config") {
		t.Fatalf("KUBECONFIG not set: %q", data)
	}
	if err := RemoveGuardHooks(f.o); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(settingsFile(f.o.home()))
	if strings.Contains(string(data), "KUBECONFIG") || strings.Contains(string(data), "--format claude") ||
		!strings.Contains(string(data), "outil-personnel") {
		t.Fatalf("settings after removal = %q", data)
	}
}

// TestGuardHooksMissingOrInvalidSettings checks the two refusal messages.
func TestGuardHooksMissingOrInvalidSettings(t *testing.T) {
	f := newFixture(t)
	if err := InstallGuardHooks(f.o); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.err.String(), "missing") {
		t.Fatalf("err = %q", f.err.String())
	}
	writeSettingsFile(t, f, "{ nope")
	f.err.Reset()
	if err := InstallGuardHooks(f.o); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(f.err.String(), "invalid JSON") {
		t.Fatalf("err = %q", f.err.String())
	}
	data, _ := os.ReadFile(settingsFile(f.o.home()))
	if string(data) != "{ nope" {
		t.Fatalf("file = %q", data)
	}
}

// TestRepowardenHooksRemovedWithoutBinary checks the jq-equivalent removal.
func TestRepowardenHooksRemovedWithoutBinary(t *testing.T) {
	f := newFixture(t)
	writeSettingsFile(t, f, `{"model":"user","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"repowarden guard --format claude"},{"type":"command","command":"outil-personnel"}]}]}}`)
	if err := removeRepowardenHooks(f.o); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(settingsFile(f.o.home()))
	if strings.Contains(string(data), "repowarden") || !strings.Contains(string(data), "outil-personnel") ||
		!strings.Contains(string(data), "user") {
		t.Fatalf("settings = %q", data)
	}
}
