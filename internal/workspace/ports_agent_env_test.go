//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsEnableWritesFoundKubectlPath checks that the definition carries the
// folder of the kubectl found at enable time, the fixed paths and KUBECONFIG.
func TestPortsEnableWritesFoundKubectlPath(t *testing.T) {
	h := newPortsEnableHarness(t)
	kubeconfig := filepath.Join(t.TempDir(), "my config")
	t.Setenv("KUBECONFIG", kubeconfig)
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable = %d, err = %q", code, errOut.String())
	}
	path := filepath.Join(h.agentDir, portsAgentName()+".service")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	wantPath := portsAgentPath + string(os.PathListSeparator) + filepath.Dir(h.kubectl)
	if !strings.Contains(string(data), "Environment=\"PATH="+systemdPercent(wantPath)+"\"\n") {
		t.Fatalf("PATH missing from definition: %q", data)
	}
	if !strings.Contains(string(data), "Environment=\"KUBECONFIG="+systemdPercent(kubeconfig)+"\"\n") {
		t.Fatalf("KUBECONFIG missing from definition: %q", data)
	}
}

// TestPortsEnableReportsMissingKubectl refuses enable with a clear message
// when no kubectl can be found in the PATH.
func TestPortsEnableReportsMissingKubectl(t *testing.T) {
	h := newPortsEnableHarness(t)
	h.noKubectl = true
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 1 {
		t.Fatalf("enable = %d, out = %q", code, out.String())
	}
	if !strings.Contains(errOut.String(), "kubectl not found") {
		t.Fatalf("error = %q, want a clear kubectl message", errOut.String())
	}
	if exists(filepath.Join(h.agentDir, portsAgentName()+".service")) {
		t.Fatal("a definition was written without kubectl")
	}
}
