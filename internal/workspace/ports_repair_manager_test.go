package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsManagerRepairsPresentDefinition checks that start and status reload
// an existing definition that the service manager no longer knows, on each
// platform, without starting a second watcher.
func TestPortsManagerRepairsPresentDefinition(t *testing.T) {
	for _, platform := range []string{"darwin", "linux", "windows"} {
		for _, command := range []string{"status", "start"} {
			t.Run(platform+"/"+command, func(t *testing.T) {
				m := newPortsFakeManager(t, platform)
				m.install()
				m.loaded = false
				m.reset()
				var out, errOut bytes.Buffer
				if code := runPortsCommand(t, command, &out, &errOut); code != 0 {
					t.Fatalf("%s = %d, err = %q", command, code, errOut.String())
				}
				if !strings.Contains(out.String(), "present but not loaded, reloaded\n") {
					t.Fatalf("%s output = %q", command, out.String())
				}
				if !m.loaded || len(m.calls) < 2 || !m.isQueryCall(m.calls[0].args) {
					t.Fatalf("loaded = %v, calls = %v", m.loaded, m.calls)
				}
				reloaded := false
				for _, call := range m.calls[1:] {
					if m.isLoadCall(call.args) {
						reloaded = true
					}
				}
				if !reloaded {
					t.Fatalf("no reload call: %v", m.calls)
				}
			})
		}
	}
}

// TestPortsManagerRecreatesMissingDefinition checks that a lost definition is
// written and loaded again when the state marker still says it is wanted.
func TestPortsManagerRecreatesMissingDefinition(t *testing.T) {
	for _, platform := range []string{"darwin", "linux", "windows"} {
		t.Run(platform, func(t *testing.T) {
			m := newPortsFakeManager(t, platform)
			m.install()
			if err := portsAgentRemove(portsAgentDir(), portsAgentName()); err != nil {
				t.Fatal(err)
			}
			m.loaded = false
			m.reset()
			var out, errOut bytes.Buffer
			if code := PortsStatus(&out); code != 0 {
				t.Fatalf("status = %d, err = %q", code, errOut.String())
			}
			if !strings.Contains(out.String(), "definition missing, recreated\n") || !portsAgentExists() || !m.loaded {
				t.Fatalf("output = %q, definition = %v, loaded = %v", out.String(), portsAgentExists(), m.loaded)
			}
			created := false
			for _, call := range m.calls {
				if m.isLoadCall(call.args) {
					created = true
				}
			}
			if !created {
				t.Fatalf("no creation call: %v", m.calls)
			}
		})
	}
}

// TestPortsManagerLeavesLoadedDefinitionAlone checks that a loaded definition
// needs only a query, so a status does not reload a watcher on every command.
func TestPortsManagerLeavesLoadedDefinitionAlone(t *testing.T) {
	for _, platform := range []string{"darwin", "linux", "windows"} {
		t.Run(platform, func(t *testing.T) {
			m := newPortsFakeManager(t, platform)
			m.install()
			var out bytes.Buffer
			if code := PortsStatus(&out); code != 0 {
				t.Fatalf("status = %d", code)
			}
			if len(m.calls) != 1 || !m.isQueryCall(m.calls[0].args) {
				t.Fatalf("calls = %v, want one query", m.calls)
			}
			if strings.Contains(out.String(), "reloaded") || strings.Contains(out.String(), "recreated") ||
				!strings.Contains(out.String(), "Port watcher automatic start: enabled\n") {
				t.Fatalf("output = %q", out.String())
			}
		})
	}
}

// TestPortsManagerRefusesOutsideDevzone checks that all three commands refuse a
// stray folder with status 1, with no service call and no file created. The
// explicit state folder of the harness is cleared: it would accept the command.
func TestPortsManagerRefusesOutsideDevzone(t *testing.T) {
	for _, command := range []string{"enable", "start", "status"} {
		t.Run(command, func(t *testing.T) {
			m := newPortsFakeManager(t, "linux")
			stateDir := os.Getenv("DEVZONE_PORTS_WORKSPACE_DIR")
			t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", "")
			outside := filepath.Join(t.TempDir(), "elsewhere")
			t.Setenv("DEVZONE_ROOT", outside)
			var out, errOut bytes.Buffer
			if code := runPortsCommand(t, command, &out, &errOut); code != 1 {
				t.Fatalf("%s = %d, want 1; out = %q, err = %q", command, code, out.String(), errOut.String())
			}
			message := errOut.String() + out.String()
			if !strings.Contains(message, "not a devzone folder") {
				t.Fatalf("message = %q", message)
			}
			if len(m.calls) != 0 || exists(filepath.Dir(m.definition())) ||
				exists(filepath.Join(stateDir, portsAutoStartWantedName)) {
				t.Fatalf("refusal left traces: calls = %v", m.calls)
			}
		})
	}
}
