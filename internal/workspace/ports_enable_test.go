//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsEnableInstallsAndDelegatesStart checks the copy, the definition, the
// service manager call and the message of a first enable.
func TestPortsEnableInstallsAndDelegatesStart(t *testing.T) {
	h := newPortsEnableHarness(t)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	data, err := os.ReadFile(h.copyPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "binary v1\n" {
		t.Fatalf("copy = %q", data)
	}
	info, err := os.Stat(h.copyPath)
	if err != nil || info.Mode()&0o111 == 0 {
		t.Fatalf("copy is not executable: %v %v", info, err)
	}
	def := filepath.Join(h.agentDir, portsAgentName()+".service")
	definition, err := os.ReadFile(def)
	if err != nil {
		t.Fatal(err)
	}
	env := portsAgentValues{path: portsAgentPath + string(os.PathListSeparator) + filepath.Dir(h.kubectl)}
	if string(definition) != portsAgentUnitText(portsAgentName(), h.copyPath, os.Getenv("DEVZONE_ROOT"), env) {
		t.Fatalf("definition = %q", definition)
	}
	if len(h.calls) != 1 || h.calls[0].tool != "systemctl" || !hasArg(h.calls[0].args, "--now") {
		t.Fatalf("daemon calls = %v", h.calls)
	}
	if h.loopCalls != 0 || !strings.Contains(out.String(), "automatic start enabled") {
		t.Fatalf("loop calls = %d, out = %q", h.loopCalls, out.String())
	}
}

// TestPortsEnableIsIdempotent replaces the copy on a second enable without
// leaving a second definition.
func TestPortsEnableIsIdempotent(t *testing.T) {
	h := newPortsEnableHarness(t)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	h.writeBinary("binary v2\n")
	out.Reset()
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	data, err := os.ReadFile(h.copyPath)
	if err != nil || string(data) != "binary v2\n" {
		t.Fatalf("copy = %q, err = %v", data, err)
	}
	entries, err := os.ReadDir(h.agentDir)
	if err != nil || len(entries) != 1 {
		t.Fatalf("definitions = %v, err = %v", entries, err)
	}
	if h.loopCalls != 0 || len(h.calls) != 3 {
		t.Fatalf("loop calls = %d, daemon calls = %d, want 0 and 3 (enable, enable, restart)", h.loopCalls, len(h.calls))
	}
}

// TestPortsEnableReportsDaemonFailure checks the non-zero status and the clear
// message on both platforms, including the unload before a launchctl bootstrap.
func TestPortsEnableReportsDaemonFailure(t *testing.T) {
	for _, tc := range []struct{ platform, tool string }{{"linux", "systemctl"}, {"darwin", "launchctl"}} {
		t.Run(tc.platform, func(t *testing.T) {
			h := newPortsEnableHarness(t)
			portsPlatform = tc.platform
			h.daemonCode = 7
			var out, errOut bytes.Buffer
			if code := PortsEnable(&out, &errOut); code != 1 {
				t.Fatalf("status = %d, err = %q", code, errOut.String())
			}
			for _, call := range h.calls {
				if call.tool != tc.tool {
					t.Fatalf("tool = %q, want %q", call.tool, tc.tool)
				}
			}
			if !strings.Contains(errOut.String(), tc.tool+" ") || !strings.Contains(errOut.String(), "status 7") {
				t.Fatalf("error = %q", errOut.String())
			}
			if strings.Contains(out.String(), "enabled") {
				t.Fatalf("success on failure: %q", out.String())
			}
		})
	}
}

// TestPortsDisableStopsAndCanBeRepeated removes the definition, stops the live
// watcher and accepts a second disable.
func TestPortsDisableStopsAndCanBeRepeated(t *testing.T) {
	h := newPortsEnableHarness(t)
	pid := h.manualWatcher()
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	out.Reset()
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatalf("disable = %d, err = %q", code, errOut.String())
	}
	if alive(pid) || portsAgentExists() || readPid(filepath.Join(h.stateDir, "pid")) != 0 {
		t.Fatal("disable left a watcher or a definition")
	}
	if !strings.Contains(out.String(), "automatic start disabled") {
		t.Fatalf("out = %q", out.String())
	}
	if code := PortsDisable(&out, &errOut); code != 0 || errOut.Len() != 0 {
		t.Fatalf("second disable = %d, err = %q", code, errOut.String())
	}
}

// TestPortsDisableReportsDaemonFailure keeps the definition when systemd
// refuses, so a retry can finish the removal; disable without a definition is
// silent and does not call the service manager.
func TestPortsDisableReportsDaemonFailure(t *testing.T) {
	h := newPortsEnableHarness(t)
	h.manualWatcher()
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	h.daemonCode = 4
	errOut.Reset()
	if code := PortsDisable(&out, &errOut); code != 4 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if !strings.Contains(errOut.String(), "status 4") || !portsAgentExists() {
		t.Fatalf("error = %q, definition left = %v", errOut.String(), portsAgentExists())
	}
	h.daemonCode = 0
	out.Reset()
	errOut.Reset()
	if code := PortsDisable(&out, &errOut); code != 0 || portsAgentExists() {
		t.Fatalf("retry = %d, definition left = %v", code, portsAgentExists())
	}
	calls := len(h.calls)
	out.Reset()
	errOut.Reset()
	if code := PortsDisable(&out, &errOut); code != 0 || errOut.Len() != 0 || len(h.calls) != calls {
		t.Fatalf("disable without definition = %d, err = %q, calls = %d", code, errOut.String(), len(h.calls))
	}
}

// TestPortsEnableSeparatesDevzoneFolders gives one definition per instance.
func TestPortsEnableSeparatesDevzoneFolders(t *testing.T) {
	h := newPortsEnableHarness(t)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	t.Setenv("DEVZONE_INSTANCE", "beta")
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	root := os.Getenv("DEVZONE_ROOT")
	alpha := filepath.Join(h.agentDir, portsAgentNameFor("alpha", root)+".service")
	beta := filepath.Join(h.agentDir, portsAgentNameFor("beta", root)+".service")
	if !exists(alpha) || !exists(beta) {
		t.Fatal("one of the two instances has no definition")
	}
	t.Setenv("DEVZONE_INSTANCE", "alpha")
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if exists(alpha) || !exists(beta) {
		t.Fatal("disable of alpha changed beta")
	}
}
