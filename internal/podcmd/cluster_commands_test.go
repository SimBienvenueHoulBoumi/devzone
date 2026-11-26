package podcmd

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

// TestPortedClusterCommandsRegistered checks that every command of the lot is
// handled by the pod binary and listed among the ported commands.
func TestPortedClusterCommandsRegistered(t *testing.T) {
	for _, name := range []string{"cluster", "clusters", "metrics", "use", "kube"} {
		if _, ok := Registry.Lookup(name); !ok {
			t.Fatalf("%s not registered", name)
		}
		if code := Run([]string{"handles", name}, io.Discard, io.Discard); code != 0 {
			t.Fatalf("handles %s: code %d, want 0", name, code)
		}
	}
	joined := "," + strings.Join(Ported(), ",") + ","
	for _, name := range []string{",clusters,", ",metrics,", ",use,", ",kube,"} {
		if !strings.Contains(joined, name) {
			t.Fatalf("Ported misses %s: %v", name, Ported())
		}
	}
}

// TestClusterShowRunsInGo checks that a bare cluster command no longer delegates
// to the shell: a fake pod script would end with code 7 if it were reached.
func TestClusterShowRunsInGo(t *testing.T) {
	podScriptForTest(t)
	t.Setenv("DEVZONE_STATE", t.TempDir()+"/modules")
	var out, errOut bytes.Buffer
	if code := Run([]string{"cluster"}, &out, &errOut); code != 0 {
		t.Fatalf("cluster: code %d, err = %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "no cluster chosen") || strings.Contains(out.String(), "args:") {
		t.Fatalf("out = %q", out.String())
	}
}

// TestKubeSavedCommand checks that the shell status can read the saved cluster
// without sourcing a library.
func TestKubeSavedCommand(t *testing.T) {
	path := t.TempDir() + "/modules"
	if err := os.WriteFile(path, []byte("cluster=host-cluster\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_STATE", path)
	var out bytes.Buffer
	if code := Run([]string{"kube", "saved"}, &out, io.Discard); code != 0 ||
		strings.TrimSpace(out.String()) != "host-cluster" {
		t.Fatalf("code = %d, out = %q", code, out.String())
	}
}

// TestKubeUnknownArgument checks the usage refusal of the kube command.
func TestKubeUnknownArgument(t *testing.T) {
	var errOut bytes.Buffer
	if code := Run([]string{"kube", "other"}, io.Discard, &errOut); code != 2 ||
		!strings.Contains(errOut.String(), "unknown argument: other") {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
}
