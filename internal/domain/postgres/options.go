// Package postgres installs and manages the shared PostgreSQL of devzone: one
// database and one role per project, in the devzone-postgres namespace of the
// chosen services cluster. It is the Go port of postgres/postgres.sh.
package postgres

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

const ns = "devzone-postgres"

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
}

// env is the execution context of one postgres subcommand.
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
		state:    state.New(statePath),
		root:     root,
		codeRoot: codeRoot,
		secrets:  filepath.Join(root, "workspace", ".postgres"),
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

// k runs kubectl on the devzone context in the postgres namespace.
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
		fmt.Fprintf(e.opts.Err, "devzone : postgres : "+format+"\n", args...)
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
		e.fail("no cluster chosen: devzone enable postgres")
		return "", false
	}
	return name, true
}

// installed reports whether the namespace exists in the services cluster.
func (e *env) installed(ctxName string) bool {
	res, err := e.kube.AccountAdmin(e.ctx, ctxName, "get", "namespace", ns)
	return err == nil && res.Code == 0
}

// relayActive reports whether the detached port-forward is still running.
func (e *env) relayActive() bool { return relay.Active(e.secrets, "postgres") }

// interactive reports whether a confirmation can be read from a terminal, as
// cluster_interactive of cluster.sh does.
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

// isTTY reports whether the psql console has a terminal on standard input.
func (e *env) isTTY() bool {
	if e.opts.TTY {
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
