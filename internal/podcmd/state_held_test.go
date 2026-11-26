package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// heldLine runs "state held <module>" on a state file holding text, and
// returns what it printed.
func heldLine(t *testing.T, text, module string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".devzone.modules")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	out := &bytes.Buffer{}
	ctx := &cli.Context{Args: []string{"held", module}, Out: out, Err: &bytes.Buffer{}}
	if code := runStateHeld(ctx, state.At(path)); code != 0 {
		t.Fatalf("held %s: code %d", module, code)
	}
	return out.String()
}

// TestStateHeldByArgoCD checks that a service on with Argo CD on is reported
// as held by an Application, for each service that Argo CD drives.
func TestStateHeldByArgoCD(t *testing.T) {
	for _, module := range []string{"gitlab", "postgres", "mysql"} {
		got := heldLine(t, module+"=on\nargocd=on\n", module)
		if got != "tenu par Argo CD : Application devzone-"+module+"\n" {
			t.Fatalf("%s: line = %q", module, got)
		}
	}
}

// TestStateHeldNothingElse checks that no line is printed when Argo CD is off,
// the module is off, or the module is not a service held by Argo CD.
func TestStateHeldNothingElse(t *testing.T) {
	cases := map[string]struct{ text, module string }{
		"argocd off":    {"gitlab=on\nargocd=off\n", "gitlab"},
		"module off":    {"gitlab=off\nargocd=on\n", "gitlab"},
		"not a service": {"kubernetes=on\nargocd=on\n", "kubernetes"},
	}
	for name, c := range cases {
		if got := heldLine(t, c.text, c.module); got != "" {
			t.Fatalf("%s: printed %q", name, got)
		}
	}
}
