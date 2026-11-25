package helm

import (
	"bytes"
	"context"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// okRunner succeeds on every command without running anything.
type okRunner struct{}

// Run implements exec.Runner.
func (okRunner) Run(context.Context, string, []string, exec.Opts) (exec.Result, error) {
	return exec.Result{}, nil
}

// TestInstallFindsRepositoryCharts checks, on the real tree, that the charts are
// found from the .devcontainer folder the launcher passes as code root.
func TestInstallFindsRepositoryCharts(t *testing.T) {
	for _, svc := range []string{"postgres", "mysql"} {
		var errOut bytes.Buffer
		if _, code := Install(context.Background(), okRunner{}, "../../../.devcontainer", svc, "devzone-"+svc, nil, &errOut); code != 0 {
			t.Fatalf("%s: code = %d, stderr = %q", svc, code, errOut.String())
		}
	}
}
