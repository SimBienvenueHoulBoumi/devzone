package podcmd

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// podScriptForTest creates a fake pod shell that records the delegated arguments.
func podScriptForTest(t *testing.T) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), "script")
	data := "#!/usr/bin/env bash\necho \"args:$*\"\necho \"from:${DEVZONE_FROM_GO:-}\"\nexit 7\n"
	if err := os.WriteFile(script, []byte(data), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_POD_SCRIPT", script)
	return script
}

// TestClusterCleanIsPorted checks that the handles command sees the Go handler.
func TestClusterCleanIsPorted(t *testing.T) {
	if rc := Run([]string{"handles", "cluster"}, io.Discard, io.Discard); rc != 0 {
		t.Fatalf("handles cluster: got %d, want 0", rc)
	}
}

// TestClusterCleanRunsInGo checks that a clean without a chosen cluster is a no-op.
func TestClusterCleanRunsInGo(t *testing.T) {
	t.Setenv("DEVZONE_ROOT", t.TempDir())
	t.Setenv("DEVZONE_WORKSPACE", "")
	podScriptForTest(t)
	var out, errOut strings.Builder
	if rc := Run([]string{"cluster", "clean"}, &out, &errOut); rc != 0 {
		t.Fatalf("cluster clean: got %d, want 0", rc)
	}
	if out.Len() != 0 || errOut.Len() != 0 {
		t.Fatalf("output = %q, error = %q", out.String(), errOut.String())
	}
}

// TestClusterCleanFlags checks that the options are accepted and unknown ones refused.
func TestClusterCleanFlags(t *testing.T) {
	t.Setenv("DEVZONE_ROOT", t.TempDir())
	t.Setenv("DEVZONE_WORKSPACE", "")
	podScriptForTest(t)
	if rc := Run([]string{"cluster", "clean", "--dry-run", "--quiet"}, io.Discard, io.Discard); rc != 0 {
		t.Fatalf("cluster clean with flags: got %d, want 0", rc)
	}
	var errOut strings.Builder
	if rc := Run([]string{"cluster", "clean", "--other"}, io.Discard, &errOut); rc != 2 {
		t.Fatalf("cluster clean --other: got %d, want 2", rc)
	}
	if !strings.Contains(errOut.String(), "unknown argument") {
		t.Fatalf("error = %q", errOut.String())
	}
}

// TestClusterDelegation checks that bare cluster and cluster CTX keep the shell
// behaviour of the other commands that are not ported.
func TestClusterDelegation(t *testing.T) {
	podScriptForTest(t)
	desktop := "doc" + "ker-desktop"
	for _, args := range [][]string{{"cluster"}, {"cluster", desktop}, {"cluster", "use", "kind-devzone"}} {
		var out strings.Builder
		if rc := Run(args, &out, io.Discard); rc != 7 {
			t.Fatalf("%v: got %d, want 7", args, rc)
		}
		if !strings.Contains(out.String(), "args:"+strings.Join(args, " ")) {
			t.Fatalf("%v: output = %q", args, out.String())
		}
		if !strings.Contains(out.String(), "from:1") {
			t.Fatalf("%v: not delegated from Go: %q", args, out.String())
		}
	}
}
