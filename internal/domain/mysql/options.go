// Package mysql installs and manages the shared MySQL of the catalog: one
// database and one user per project in the devzone-mysql namespace. It is the
// Go port of catalog/mysql/mysql.sh, install.sh and volume.sh.
package mysql

import (
	"bufio"
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

const ns = "devzone-mysql"

// Options carries the collaborators, the paths and the switches of a run.
type Options struct {
	Runner      exec.Runner
	Out         io.Writer
	Err         io.Writer
	Stdin       io.Reader
	Root        string
	CodeRoot    string
	StatePath   string
	Interactive bool
	TTY         bool
	Launcher    relay.Launcher
	Sleep       func(time.Duration)
}

// env is the execution context of one mysql subcommand.
type env struct {
	ctx      context.Context
	opts     Options
	kube     kube.Kube
	state    *state.State
	root     string
	codeRoot string
	secrets  string
}

// newEnv builds an execution context with the defaults of the shell module.
func newEnv(ctx context.Context, opts Options) *env {
	if ctx == nil {
		ctx = context.Background()
	}
	root := opts.Root
	if root == "" {
		root = os.Getenv("DEVZONE_ROOT")
	}
	if root == "" {
		root, _ = os.Getwd()
	}
	codeRoot := opts.CodeRoot
	if codeRoot == "" {
		codeRoot = os.Getenv("DEVZONE_POD_SCRIPT")
		if codeRoot != "" {
			codeRoot = filepath.Dir(codeRoot)
		}
	}
	statePath := opts.StatePath
	if statePath == "" {
		if path := os.Getenv("DEVZONE_STATE"); path != "" {
			statePath = path
		} else {
			statePath = filepath.Join(root, ".devzone.modules")
		}
	}
	return &env{
		ctx:      ctx,
		opts:     opts,
		kube:     kube.Kube{Runner: opts.Runner},
		state:    state.At(statePath),
		root:     root,
		codeRoot: codeRoot,
		secrets:  filepath.Join(root, "workspace", ".mysql"),
	}
}

// runner returns the runner of this run, or the real one.
func (e *env) runner() exec.Runner {
	if e.opts.Runner != nil {
		return e.opts.Runner
	}
	return exec.ExecRunner{}
}

// exec runs a command through the framework runner.
func (e *env) exec(name string, args []string, stdin io.Reader) (exec.Result, error) {
	return e.runner().Run(e.ctx, name, args, exec.Opts{Stdin: stdin})
}

// execEnv runs a command with an explicit environment, for the shell libraries.
func (e *env) execEnv(name string, args []string, stdin io.Reader, env []string) (exec.Result, error) {
	return e.runner().Run(e.ctx, name, args, exec.Opts{Stdin: stdin, Env: env})
}

// k runs kubectl on the devzone context in the mysql namespace.
func (e *env) k(args ...string) (exec.Result, error) {
	return e.exec("kubectl", append([]string{"--context", "devzone", "-n", ns}, args...), nil)
}

// kInput runs kubectl with data on standard input.
func (e *env) kInput(stdin io.Reader, args ...string) (exec.Result, error) {
	return e.exec("kubectl", append([]string{"--context", "devzone", "-n", ns}, args...), stdin)
}

// show writes the captured output of a command as the shell would.
func (e *env) show(res exec.Result) {
	if e.opts.Out != nil {
		_, _ = e.opts.Out.Write(res.Stdout)
	}
	e.showErr(res)
}

// showErr writes the captured standard error of a command.
func (e *env) showErr(res exec.Result) {
	if e.opts.Err != nil && len(res.Stderr) > 0 {
		_, _ = e.opts.Err.Write(res.Stderr)
	}
}

// fail writes a refusal message and returns the shell refusal status.
func (e *env) fail(format string, args ...any) int {
	if e.opts.Err != nil {
		fmt.Fprintf(e.opts.Err, "devzone : catalog mysql : "+format+"\n", args...)
	}
	return 2
}

// line writes one line on standard output.
func (e *env) line(format string, args ...any) {
	if e.opts.Out != nil {
		fmt.Fprintf(e.opts.Out, format+"\n", args...)
	}
}

// setting returns an environment override or its default value.
func setting(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

// cluster returns the chosen services cluster from the state file.
func (e *env) cluster() string { return strings.TrimSpace(e.state.Get("cluster")) }

// moduleContext returns the chosen cluster, refusing when none is saved.
func (e *env) moduleContext() (string, bool) {
	name := e.cluster()
	if name == "" {
		e.fail("no cluster chosen: devzone enable mysql")
		return "", false
	}
	return name, true
}

// namespaceExists reports whether ns exists in the services cluster.
func (e *env) namespaceExists(ctxName, namespace string) bool {
	res, err := e.kube.AccountAdmin(e.ctx, ctxName, "get", "namespace", namespace)
	return err == nil && res.Code == 0
}

// installed reports whether the mysql namespace exists.
func (e *env) installed(ctxName string) bool { return e.namespaceExists(ctxName, ns) }

// activeAdminContext returns the admin context of the installation.
func (e *env) activeAdminContext() string {
	return e.kube.AccountContext(e.cluster())
}

// relayActive reports whether the detached port-forward is still running.
func (e *env) relayActive() bool { return relay.Active(e.secrets, "mysql") }

// interactive reports whether a confirmation can be read from a terminal.
func (e *env) interactive() bool {
	if e.opts.Interactive || os.Getenv("DEVZONE_INTERACTIVE") == "1" {
		return true
	}
	if e.opts.Stdin != nil {
		return false
	}
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// answer reads one line from the confirmation prompt.
func (e *env) answer() string {
	if e.opts.Stdin == nil {
		return ""
	}
	line, err := bufio.NewReader(e.opts.Stdin).ReadString('\n')
	if err != nil && line == "" {
		return ""
	}
	return strings.TrimRight(line, "\r\n")
}

// sleep waits between two rollout polls; tests replace it with a no-op.
func (e *env) sleep(d time.Duration) {
	if e.opts.Sleep != nil {
		e.opts.Sleep(d)
		return
	}
	time.Sleep(d)
}

// regenerate rebuilds the grouped credentials view with the shared library.
func (e *env) regenerate() {
	if e.codeRoot == "" {
		return
	}
	res, err := e.exec("bash", []string{filepath.Join(e.codeRoot, "password.sh"), "regenerate"}, nil)
	if err != nil || res.Code != 0 {
		e.showErr(res)
		if e.opts.Err != nil {
			fmt.Fprintln(e.opts.Err, "devzone : catalog mysql : grouped credentials not updated (devzone passwords)")
		}
	}
}
