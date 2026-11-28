package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestApplyWorkspaceManifestUsesCurrentContext checks that a kubeconfig without
// the services context applies the manifest on the current context.
func TestApplyWorkspaceManifestUsesCurrentContext(t *testing.T) {
	runner := fake.New()
	runner.On("kubectl", nil, fexec.Result{})
	ctx := &cli.Context{Runner: runner, Err: &bytes.Buffer{}}
	if code := applyWorkspaceManifest(ctx, "kind: Application\n"); code != 0 {
		t.Fatalf("apply code = %d", code)
	}
	for _, call := range runner.Calls() {
		if call.Name != "kubectl" {
			continue
		}
		line := strings.Join(call.Args, " ")
		if strings.Contains(line, "--context") {
			t.Errorf("services context forced without declaration: %q", line)
		}
		if len(call.Args) > 1 && call.Args[len(call.Args)-2] == "-f" && call.Args[len(call.Args)-1] == "-" {
			return
		}
	}
	t.Fatalf("no manifest apply in %v", runner.Calls())
}

// TestContextFlagUsesSharedChooser checks that the command flag follows the
// configured context name instead of a literal written in the command.
func TestContextFlagUsesSharedChooser(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		fexec.Result{Stdout: []byte("kind-lab\n")})
	runner.On("kubectl", nil, fexec.Result{})
	if !argoCDHoldsWorkspace(runner, t.TempDir()+"/.devzone.modules") {
		t.Fatalf("Argo CD not found with the configured context: %v", runner.Calls())
	}
}
