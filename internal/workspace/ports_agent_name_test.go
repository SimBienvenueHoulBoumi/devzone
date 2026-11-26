//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsAgentNameIncludesDevzoneFolder checks that two folders of the same
// instance get different definition names: the absolute path is hashed in.
func TestPortsAgentNameIncludesDevzoneFolder(t *testing.T) {
	newPortsEnableHarness(t)
	first := portsAgentName()
	folder := filepath.Join(t.TempDir(), "second")
	t.Setenv("DEVZONE_ROOT", folder)
	second := portsAgentName()
	if first == second {
		t.Fatalf("both folders use %q", first)
	}
	if !strings.HasPrefix(first, portsAgentPrefix+"alpha-") || !strings.HasPrefix(second, portsAgentPrefix+"alpha-") {
		t.Fatalf("names = %q, %q, want the instance and a folder hash", first, second)
	}
	t.Setenv("DEVZONE_ROOT", folder)
	if got := portsAgentName(); got != second {
		t.Fatalf("name is not stable: %q, want %q", got, second)
	}
}

// TestPortsEnableKeepsOneDefinitionPerFolder checks that enabling two folders
// of the same instance writes two definitions and that disable only removes
// the one of the current folder.
func TestPortsEnableKeepsOneDefinitionPerFolder(t *testing.T) {
	h := newPortsEnableHarness(t)
	firstRoot := os.Getenv("DEVZONE_ROOT")
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	first := portsAgentName()
	secondRoot := filepath.Join(t.TempDir(), "other folder")
	t.Setenv("DEVZONE_ROOT", secondRoot)
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	second := portsAgentName()
	if first == second || !exists(filepath.Join(h.agentDir, first+".service")) ||
		!exists(filepath.Join(h.agentDir, second+".service")) {
		t.Fatalf("definitions = %q and %q", first, second)
	}
	t.Setenv("DEVZONE_ROOT", firstRoot)
	if code := PortsDisable(&out, &errOut); code != 0 {
		t.Fatal(errOut.String())
	}
	if exists(filepath.Join(h.agentDir, first+".service")) || !exists(filepath.Join(h.agentDir, second+".service")) {
		t.Fatal("disable removed the wrong folder's definition")
	}
}
