// Package catalog implements "devzone catalog" and its watcher in Go: one
// application per folder of the catalog, installed on the services cluster
// according to the <app>=on|off lines of .devzone.modules. It is the port of
// catalog.sh, catalog/app.sh, catalog/catalog-watcher.sh and chart-direct.sh;
// every external tool goes through the injected runner so tests use fakes.
package catalog

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// Options carries the collaborators, the folders and the injectable timing of
// one catalog command or watcher.
type Options struct {
	Runner    exec.Runner
	Out       io.Writer
	Err       io.Writer
	Stdin     io.Reader
	Root      string
	CodeRoot  string
	StatePath string
	Launcher  relay.Launcher
	Sleep     func(time.Duration)
	Step      time.Duration
}

// env is the execution context of one catalog command.
type env struct {
	ctx       context.Context
	opts      Options
	kube      kube.Kube
	state     *state.State
	root      string
	codeRoot  string
	statePath string
	catalog   string
	watcher   string
	script    string
}

// newEnv resolves the folders of the command exactly as the shell entry point
// did: explicit options, then the DEVZONE_* environment, then the devzone root.
func newEnv(ctx context.Context, opts Options) *env {
	if ctx == nil {
		ctx = context.Background()
	}
	root := opts.Root
	if root == "" {
		root = os.Getenv("DEVZONE_ROOT")
	}
	code := opts.CodeRoot
	if code == "" {
		code = os.Getenv("DEVZONE_POD_SCRIPT")
		if code != "" {
			code = filepath.Dir(code)
		}
	}
	if root == "" && code != "" {
		root = filepath.Dir(code)
	}
	if root == "" {
		root, _ = os.Getwd()
	}
	path := opts.StatePath
	if path == "" {
		path = os.Getenv("DEVZONE_STATE")
	}
	if path == "" {
		path = filepath.Join(root, ".devzone.modules")
	}
	dir := os.Getenv("DEVZONE_CATALOG")
	if dir == "" {
		dir = filepath.Join(code, "catalog")
	}
	base := os.Getenv("DEVZONE_CATALOG_WATCHER_DIR")
	if base == "" {
		base = filepath.Join(root, ".devzone.catalog-watcher")
	}
	return &env{
		ctx:       ctx,
		opts:      opts,
		kube:      kube.Kube{Runner: opts.Runner},
		state:     state.At(path),
		root:      root,
		codeRoot:  code,
		statePath: path,
		catalog:   dir,
		watcher:   base,
		script:    filepath.Join(code, "devzone"),
	}
}

// runner returns the injected runner, or the real process runner.
func (e *env) runner() exec.Runner {
	if e.opts.Runner != nil {
		return e.opts.Runner
	}
	return exec.ExecRunner{}
}

// exec runs a command through the framework runner with no standard input.
func (e *env) exec(name string, args []string, envVars ...string) (exec.Result, error) {
	opts := exec.Opts{}
	if len(envVars) > 0 {
		opts.Env = envVars
	}
	return e.runner().Run(e.ctx, name, args, opts)
}

// k runs kubectl on the devzone context in the namespace ns.
func (e *env) k(ns string, args ...string) (exec.Result, error) {
	return e.exec("kubectl", append([]string{"--context", "devzone", "-n", ns}, args...))
}

// out writes one line on the standard output of the command.
func (e *env) out(format string, args ...any) {
	if e.opts.Out != nil {
		_, _ = io.WriteString(e.opts.Out, formatLine(format, args...))
	}
}

// warn writes one line on the error output of the command.
func (e *env) warn(format string, args ...any) {
	if e.opts.Err != nil {
		_, _ = io.WriteString(e.opts.Err, formatLine(format, args...))
	}
}

// formatLine renders a printf format with a trailing newline.
func formatLine(format string, args ...any) string {
	return fmt.Sprintf(strings.TrimSuffix(format, "\n")+"\n", args...)
}

// refuse writes the shell refusal line and returns its exit status 2.
func (e *env) refuse(format string, args ...any) int {
	e.warn("devzone : catalog : "+format, args...)
	return 2
}

// sleep waits through the injected function, a no-op in the tests.
func (e *env) sleep(d time.Duration) {
	if e.opts.Sleep != nil {
		e.opts.Sleep(d)
		return
	}
	time.Sleep(d)
}

// cluster returns the chosen services cluster saved in the state.
func (e *env) cluster() string { return strings.TrimSpace(e.state.Get("cluster")) }

// setting returns an environment override or its default value.
func setting(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

// captured returns an environment that records its output in a builder, as
// the shell command substitutions of app_install and app_remove did.
func (e *env) captured() (*env, *strings.Builder) {
	var b strings.Builder
	clone := *e
	clone.opts.Out = &b
	clone.opts.Err = &b
	return &clone, &b
}
