package command

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestDeployWorkspaceAtRequiresArgoCD checks that an update stops with the
// enable command instead of installing the chart directly when Argo CD is off.
func TestDeployWorkspaceAtRequiresArgoCD(t *testing.T) {
	state := filepath.Join(t.TempDir(), ".devzone.modules")
	if err := os.WriteFile(state, []byte("argocd=off\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_STATE", state)
	t.Setenv("DEVZONE_ARGOCD_REVISION", "")
	runner := fake.New()
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	ctx := &cli.Context{Args: []string{"deploy", "registry/example", "1.2.3", ""}, Out: out, Err: errOut, Runner: runner}
	if code := deployWorkspaceAt(ctx, "registry/example", "1.2.3", "v1.0.0"); code != 1 {
		t.Fatalf("code = %d, stderr = %q", code, errOut.String())
	}
	want := "devzone : workspace : Argo CD is required but not running,\nplease run: devzone enable argocd\n"
	if errOut.String() != want {
		t.Errorf("stderr = %q, want %q", errOut.String(), want)
	}
	for _, call := range runner.Calls() {
		if call.Name == "helm" {
			t.Errorf("direct chart fallback ran: %v", call.Args)
		}
	}
	if got := os.Getenv("DEVZONE_ARGOCD_REVISION"); got != "" {
		t.Errorf("revision was not restored: %q", got)
	}
}
