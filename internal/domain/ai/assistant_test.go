package ai

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// withCode installs fake templates and a state file in the fixture.
func withCode(t *testing.T, f fixture) fixture {
	t.Helper()
	dir := t.TempDir()
	files := map[string]string{
		"opencode.jsonc":                 opencodeMarker + "\n{}\n",
		"ai/plugins/devzone-guard.js":    "const guard = \"__DEVZONE_" + "\x44\x4f\x43\x4b\x45\x52" + "_GUARD__\";\n",
		"ai/plugins/devzone-guard-v2.js": "const guard = \"__DEVZONE_" + "\x44\x4f\x43\x4b\x45\x52" + "_GUARD__\";\n",
		"skills/devzone/SKILL.md":        skillMarker + "\n# devzone\n",
	}
	for name, content := range files {
		path := filepath.Join(dir, name)
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	f.o.DevcontainerDir = dir
	f.o.StateFile = filepath.Join(t.TempDir(), "etat")
	settings := settingsFile(f.o.home())
	os.MkdirAll(filepath.Dir(settings), 0o755)
	if err := os.WriteFile(settings, []byte(`{"model":"user","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"outil-personnel"}]}]}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return f
}

// programEnable programs the fake commands of a successful installation.
func programEnable(f fixture, code int) {
	for _, pkg := range []string{claudePackage, opencodePackage} {
		f.r.On("npm", []string{"install", "-g", "--no-fund", "--no-audit", "--loglevel=error", pkg},
			dzexec.Result{Code: code})
	}
	for _, binary := range []string{"claude", "opencode"} {
		f.r.On(binary, []string{"--version"}, dzexec.Result{Stdout: []byte("1.0.0\n")})
	}
	f.r.On("repowarden", []string{"agents", "init", "--global"}, dzexec.Result{})
	f.r.On("devzone", []string{"state", "write", "ai", "on"}, dzexec.Result{})
	f.tags(`{"models":[]}`)
}

// TestEnableInstallsAssistantsAndGuard checks the whole installation path.
func TestEnableInstallsAssistantsAndGuard(t *testing.T) {
	f := withCode(t, newFixture(t))
	programEnable(f, 0)
	if code := Enable(ctx(), f.o); code != 0 {
		t.Fatalf("code = %d, err = %q", code, f.err.String())
	}
	installs := 0
	for _, call := range f.r.Calls() {
		if call.Name == "npm" && len(call.Args) > 0 && call.Args[0] == "install" {
			installs++
		}
	}
	if installs != 2 {
		t.Fatalf("install calls = %d", installs)
	}
	if !strings.Contains(f.out.String(), "Claude Code and opencode installed") ||
		!strings.Contains(f.out.String(), "ai active: claude") {
		t.Fatalf("out = %q", f.out.String())
	}
	settings, err := os.ReadFile(settingsFile(f.o.home()))
	if err != nil || !strings.Contains(string(settings), "--format claude") ||
		!strings.Contains(string(settings), "KUBECONFIG") {
		t.Fatalf("settings = %q, %v", settings, err)
	}
	for _, name := range []string{"devzone-guard.js", "devzone-guard-v2.js"} {
		path := filepath.Join(f.o.home(), ".config", "opencode", "plugins", name)
		data, err := os.ReadFile(path)
		if err != nil || strings.Contains(string(data), "GUARD__") {
			t.Fatalf("plugin %s = %q, %v", name, data, err)
		}
	}
	if _, err := os.Stat(filepath.Join(f.o.home(), ".config", "opencode", "opencode.jsonc")); err != nil {
		t.Fatalf("opencode config: %v", err)
	}
}

// TestEnableFailureMarksModule checks the three attempts and the failure marker.
func TestEnableFailureMarksModule(t *testing.T) {
	f := withCode(t, newFixture(t))
	programEnable(f, 1)
	if code := Enable(ctx(), f.o); code != 1 {
		t.Fatalf("code = %d", code)
	}
	attempts := 0
	for _, call := range f.r.Calls() {
		if call.Name == "npm" && len(call.Args) > 0 && call.Args[0] == "install" {
			attempts++
		}
	}
	if attempts != 6 {
		t.Fatalf("attempts = %d, want 6", attempts)
	}
	marker, err := os.ReadFile(f.o.failureMarker("ai"))
	if err != nil || !strings.Contains(string(marker), "npm log:") {
		t.Fatalf("marker = %q, %v", marker, err)
	}
	if !strings.Contains(f.err.String(), "opencode-ai@") {
		t.Fatalf("err = %q", f.err.String())
	}
}

// TestDisableRestoresHome checks the symmetrical removal after an install.
func TestDisableRestoresHome(t *testing.T) {
	f := withCode(t, newFixture(t))
	programEnable(f, 0)
	Enable(ctx(), f.o)
	f.r.On("npm", []string{"uninstall", "-g", "@anthropic-ai/claude-code", "opencode-ai"}, dzexec.Result{})
	f.r.On("repowarden", []string{"agents", "retirer", "--global"}, dzexec.Result{})
	f.r.On("devzone", []string{"state", "write", "ai", "off"}, dzexec.Result{})
	f.tags(`{"models":[]}`)
	if code := Disable(ctx(), f.o); code != 0 {
		t.Fatalf("code = %d", code)
	}
	for _, name := range []string{"devzone-guard.js", "devzone-guard-v2.js"} {
		path := filepath.Join(f.o.home(), ".config", "opencode", "plugins", name)
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("plugin remains: %v", err)
		}
	}
	settings, err := os.ReadFile(settingsFile(f.o.home()))
	if err != nil || strings.Contains(string(settings), "--format claude") || !strings.Contains(string(settings), "outil-personnel") {
		t.Fatalf("settings = %q, %v", settings, err)
	}
	if !strings.Contains(f.out.String(), "ai disabled") {
		t.Fatalf("out = %q", f.out.String())
	}
}
