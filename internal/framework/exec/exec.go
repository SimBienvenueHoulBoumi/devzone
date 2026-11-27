// Package exec provides a small abstraction over running external commands, so
// that code can be tested with a fake runner instead of the real process.
package exec

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/gitenv"
)

// Opts carries the optional inputs of a command run: standard input, environment
// and working directory.
type Opts struct {
	Stdin io.Reader
	Env   []string
	Dir   string
}

// Result holds the captured output and exit status of a finished command.
type Result struct {
	Stdout []byte
	Stderr []byte
	Code   int
}

// Runner runs an external command and returns its result. A nil error means the
// command ran (even with a non-zero exit status); a non-nil error means it
// could not be started.
type Runner interface {
	Run(ctx context.Context, name string, args []string, opts Opts) (Result, error)
}

// ExecRunner is the real implementation, backed by os/exec.
type ExecRunner struct{}

// Run starts name with args and waits for it to finish.
func (ExecRunner) Run(ctx context.Context, name string, args []string, opts Opts) (Result, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	// When the context kills the command, return after a short grace instead
	// of blocking on output pipes still held by orphaned children.
	cmd.WaitDelay = time.Second
	if opts.Stdin != nil {
		cmd.Stdin = opts.Stdin
	}
	if opts.Dir != "" {
		cmd.Dir = opts.Dir
	}
	// Opts.Env is added to the environment of this process, never replaces it:
	// without HOME, kubectl writes its cache in the current folder (.kube/cache),
	// and PATH, proxies or locale would be lost (#863)
	base, extra := os.Environ(), opts.Env
	if name == "git" {
		// A hook's GIT_DIR overrides "git -C folder": drop it on both sides so
		// git reads and writes the folder this command was given (#878).
		base, extra = gitenv.Clean(base), gitenv.Clean(extra)
	}
	cmd.Env = base
	if len(extra) > 0 {
		cmd.Env = append(base, extra...)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	res := Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
	if err == nil {
		return res, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		res.Code = exitErr.ExitCode()
		return res, nil
	}
	return res, err
}
