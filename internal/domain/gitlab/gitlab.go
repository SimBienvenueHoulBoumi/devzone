// Package gitlab runs GitLab in the services cluster (#396): installation,
// chart, Argo CD, seed, secrets and status, with kubectl and helm through the
// runner of the framework and the administrator context of internal/platform/kube.
package gitlab

import (
	"context"
	"fmt"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"io"
	"os"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// testBaseURL, when not empty, replaces the GitLab address in the HTTP calls
// (the tests of the Go port point it at a local server).
var testBaseURL string

// baseURL is the address of the GitLab of the module.
func baseURL() string {
	if testBaseURL != "" {
		return testBaseURL
	}
	return config.GitLab().WebURL()
}

// Options carries the collaborators and the switches of one gitlab run.
type Options struct {
	Runner       exec.Runner
	Out          io.Writer
	Err          io.Writer
	Root         string // devzone root RACINE; "" reads DEVZONE_ROOT
	ProcessAlive func(pid string) bool
	StartRelay   func(name, dir string, args []string) (string, error)
	Now          func() time.Time
	Sleep        func(time.Duration)
}

// run holds the shared collaborators of one gitlab command run.
type run struct {
	ctx   context.Context
	opts  Options
	root  string
	state string // path of .devzone.modules
	ns    string // namespace of the instance, devzone-gitlab + suffix
	now   func() time.Time
	sleep func(time.Duration)
}

// newRun builds the run from the options, reading the root, the state and the
// instance suffix as the shell scripts did.
func newRun(ctx context.Context, opts Options) *run {
	root := opts.Root
	if root == "" {
		root = os.Getenv("DEVZONE_ROOT")
	}
	if root == "" {
		root = "."
	}
	statePath := os.Getenv("DEVZONE_STATE")
	if statePath == "" {
		statePath = root + "/.devzone.modules"
	}
	r := &run{ctx: ctx, opts: opts, root: root, state: statePath, now: opts.Now, sleep: opts.Sleep}
	if r.now == nil {
		r.now = time.Now
	}
	if r.sleep == nil {
		r.sleep = time.Sleep
	}
	return r
}

// instanceSuffix returns the instance suffix of the module (DEVZONE_INSTANCE,
// "" or "devzone" for the default instance), like cluster.sh.
func instanceSuffix() string {
	instance := os.Getenv("DEVZONE_INSTANCE")
	if instance != "" && instance != "devzone" {
		return "-" + instance
	}
	return ""
}

// out returns the standard output, never nil.
func (r *run) out() io.Writer {
	if r.opts.Out != nil {
		return r.opts.Out
	}
	return io.Discard
}

// errOut returns the standard error, never nil.
func (r *run) errOut() io.Writer {
	if r.opts.Err != nil {
		return r.opts.Err
	}
	return io.Discard
}

// namespace is the namespace of the instance: devzone-gitlab + suffix.
func (r *run) namespace() string {
	if r.ns == "" {
		r.ns = config.NamespaceGitLab + instanceSuffix()
	}
	return r.ns
}

// Run runs the gitlab subcommand line (the words after "gitlab") and returns
// the exit status, as the shell entry point did: an unknown subcommand prints
// the message of the shell on the standard error, code 1.
func Run(ctx context.Context, args []string, opts Options) int {
	if ctx == nil {
		ctx = context.Background()
	}
	r := newRun(ctx, opts)
	cmd := ""
	var rest []string
	if len(args) > 0 {
		cmd = args[0]
		rest = args[1:]
	}
	switch cmd {
	case "install":
		return r.install()
	case "uninstall":
		return r.uninstall(rest)
	case "migrate":
		return r.migrate(rest)
	case "installed":
		return r.installed()
	case "status":
		return r.status()
	case "seed":
		return r.seedCommand()
	case "new-password":
		return r.newPassword(rest)
	case "relay-start":
		r.gitlabRelayStart()
		return 0
	case "relay-stop":
		r.gitlabRelayStop()
		return 0
	case "relay-status":
		return r.relayStatus()
	case "host-set":
		return r.hostSet()
	case "host-remove":
		return r.hostRemove()
	default:
		fmt.Fprintf(r.errOut(), "devzone : unknown command : %s (devzone gitlab --help)\n", cmd)
		return 1
	}
}

// unused keeps strings imported when the file is the only one touched.
var _ = strings.TrimSpace
