package command

import (
	"bytes"
	"context"
	"io"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// stubValuesEnsure replaces the Argo CD library call of the workstation for
// one test, so no host command or GitOps API is reached from this package.
func stubValuesEnsure(t *testing.T, code int) *[]string {
	t.Helper()
	previous := workstationArgoCDRun
	t.Cleanup(func() { workstationArgoCDRun = previous })
	calls := &[]string{}
	workstationArgoCDRun = func(_ context.Context, args []string, _, _ io.Writer, _ argocd.Options) int {
		*calls = append(*calls, strings.Join(args, " "))
		return code
	}
	return calls
}

// TestWorkspaceApplyEnsuresValuesOnEachStart checks that writing the workspace
// Application in GitOps asks the library for the values file on every start.
func TestWorkspaceApplyEnsuresValuesOnEachStart(t *testing.T) {
	hostMode(t)
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_ARGOCD_CONF", "")
	writeDeployFile(t, filepath.Join(root, ".argocd.conf"),
		"[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n")
	calls := stubValuesEnsure(t, 0)
	r := fake.New()
	r.On("gh", nil, fexec.Result{})
	r.On("kubectl", nil, fexec.Result{})
	errOut := &bytes.Buffer{}
	ctx := &cli.Context{Err: errOut, Runner: r}
	for i := 0; i < 2; i++ {
		if code := workspaceApplyApplication(ctx, root, "https://github.com/acme/devzone.git",
			"v1.2.3", []string{"image.tag=1.2.3"}); code != 0 {
			t.Fatalf("start %d: code=%d err=%q", i, code, errOut.String())
		}
	}
	if got := strings.Join(*calls, ","); got != "values-ensure,values-ensure" {
		t.Fatalf("library calls = %q, want two values-ensure", got)
	}
}
