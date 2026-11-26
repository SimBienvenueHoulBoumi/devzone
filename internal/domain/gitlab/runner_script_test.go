package gitlab

import (
	"context"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// scriptedRunner answers the gitlab-rails runner calls from the script on
// their standard input and delegates every other call to the inner fake; it
// lets a test prove which script the seed really sends.
type scriptedRunner struct {
	inner *fake.Runner
	rails func(script string) exec.Result
}

// Run implements exec.Runner.
func (s *scriptedRunner) Run(ctx context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	if name == "kubectl" && hasRailsRunner(args) {
		script := ""
		if opts.Stdin != nil {
			data, err := io.ReadAll(opts.Stdin)
			if err != nil {
				return exec.Result{}, err
			}
			script = string(data)
		}
		return s.rails(script), nil
	}
	return s.inner.Run(ctx, name, args, opts)
}

// hasRailsRunner reports whether args run gitlab-rails runner on standard
// input.
func hasRailsRunner(args []string) bool {
	for i, a := range args {
		if a == "gitlab-rails" && i+1 < len(args) && args[i+1] == "runner" {
			return true
		}
	}
	return false
}

// runWithScriptedRails runs the gitlab command with the gitlab-rails runner
// answered from the received script.
func (f *fixture) runWithScriptedRails(rails func(string) exec.Result, args ...string) int {
	opts := f.opts()
	opts.Runner = &scriptedRunner{inner: f.r, rails: rails}
	return Run(context.Background(), args, opts)
}
