package workspace

import (
	"bytes"
	"context"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// ContextRunner adapts a workspace Runner to the framework Runner so that the
// shared context chooser can be used by the workspace commands (#916).
type ContextRunner struct{ Runner Runner }

// Run executes kubectl through the adapted workspace Runner and collects its
// output in a framework result.
func (c ContextRunner) Run(ctx context.Context, name string, args []string, opts fexec.Opts) (fexec.Result, error) {
	var stdout, stderr bytes.Buffer
	status, err := c.Runner.Kubectl(args, opts.Stdin, &stdout, &stderr)
	return fexec.Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), Code: status}, err
}

// contextFlag returns the shared kubectl flag that selects services context.
func contextFlag(r Runner) []string {
	return fexec.DevzoneKubectlContextFlag(context.Background(), ContextRunner{Runner: r})
}

// helmContextFlag returns the shared helm flag that selects services context.
func helmContextFlag(r Runner) []string {
	return fexec.DevzoneHelmContextFlag(context.Background(), ContextRunner{Runner: r})
}
