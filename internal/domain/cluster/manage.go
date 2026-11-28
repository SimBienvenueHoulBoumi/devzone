package cluster

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// ManageOptions carries the collaborators of the cluster and use commands.
type ManageOptions struct {
	Runner      exec.Runner
	Out         io.Writer
	Err         io.Writer
	Stdin       io.Reader
	StatePath   string
	Interactive bool
	Remote      string
	Install     func() int
}

// out returns the standard output writer of one run.
func (o ManageOptions) out() io.Writer { return writerOrDiscard(o.Out) }

// errOut returns the error writer of one run.
func (o ManageOptions) errOut() io.Writer { return writerOrDiscard(o.Err) }

// writerOrDiscard keeps a writer usable when a test did not provide one.
func writerOrDiscard(w io.Writer) io.Writer {
	if w == nil {
		return io.Discard
	}
	return w
}

// isInteractive reports whether a confirmation can be read from a terminal,
// as cluster_interactive of cluster.sh did.
func (o ManageOptions) isInteractive() bool {
	if o.Interactive || os.Getenv("DEVZONE_INTERACTIVE") == "1" {
		return true
	}
	if o.Stdin != nil {
		return false
	}
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// answer reads one line of confirmation from the injected standard input.
func (o ManageOptions) answer() string {
	if o.Stdin == nil {
		return ""
	}
	line, _ := bufio.NewReader(o.Stdin).ReadString('\n')
	return strings.TrimRight(line, "\r\n")
}

// yesAnswer reports whether a confirmation line accepts the operation.
func yesAnswer(answer string) bool {
	switch answer {
	case "y", "Y", "yes":
		return true
	}
	return false
}

// newKube builds the kubectl facade of one cluster command.
func (o ManageOptions) newKube() kube.Kube { return kube.Kube{Runner: o.Runner} }

// Change handles "devzone cluster [CTX] [--yes] [--confirm CTX]": it shows the
// services cluster or moves the services to the chosen one, as change_cluster.
func Change(ctx context.Context, opts ManageOptions, args []string) int {
	if ctx == nil {
		ctx = context.Background()
	}
	wanted, confirm, yes := "", "", false
	expect := false
	for _, arg := range args {
		if expect {
			confirm, expect = arg, false
			continue
		}
		switch {
		case arg == "--yes":
			yes = true
		case arg == "--confirm":
			expect = true
		case strings.HasPrefix(arg, "-"):
			fmt.Fprintf(opts.errOut(), "devzone : unknown argument: %s (devzone cluster [CTX] [--yes] [--confirm CTX])\n", arg)
			return 2
		default:
			wanted = arg
		}
	}
	if expect {
		fmt.Fprintln(opts.errOut(), "devzone : --confirm expects a context")
		return 2
	}
	k := opts.newKube()
	current := kube.SavedContext(opts.StatePath)
	if wanted == "" {
		switch {
		case current == "":
			fmt.Fprintln(opts.out(), "devzone : no cluster chosen (set when a module is enabled: devzone enable postgres)")
		case kube.IsDedicated(current):
			fmt.Fprintf(opts.out(), "devzone : cluster %s (dedicated kind, in the container)\n", current)
		default:
			fmt.Fprintf(opts.out(), "devzone : cluster %s (host cluster)\n", current)
		}
		candidates, err := k.Candidates(ctx)
		if err != nil {
			return 1
		}
		fmt.Fprintf(opts.out(), "  possible: %s\n", strings.Join(candidates, " ")+" ")
		return 0
	}
	choice := kube.ChooseOptions{Wanted: wanted, Confirm: confirm, Saved: current,
		Remote: opts.Remote, Interactive: opts.isInteractive(), Stdin: opts.Stdin, Out: opts.out(), Err: opts.errOut()}
	next, code := k.Choose(ctx, choice)
	if code != 0 {
		return 2
	}
	if next == current {
		fmt.Fprintf(opts.out(), "devzone : already on %s, nothing to do.\n", next)
		return 0
	}
	if statePostgresOn(opts.StatePath) {
		if !yes {
			if !opts.isInteractive() {
				fmt.Fprintf(opts.errOut(), "devzone : the postgres databases will be deleted from %s (not migrated): devzone cluster %s --yes\n", current, next)
				return 1
			}
			fmt.Fprintf(opts.errOut(), "postgres will be reinstalled on %s, its databases deleted from %s (not migrated). Continue? [y/N] ", next, current)
			if !yesAnswer(opts.answer()) {
				fmt.Fprintln(opts.out(), "Aborted: nothing changed.")
				return 0
			}
		}
		_ = k.AccountRemove(ctx, current, config.NamespacePostgres)
		_, _ = k.AccountAdmin(ctx, current, "delete", "namespace", config.NamespacePostgres, "--wait=true")
		_ = k.ClusterRelease(ctx, current, opts.out(), opts.errOut())
	}
	if err := kube.SaveContext(opts.StatePath, next); err != nil {
		fmt.Fprintln(opts.errOut(), err)
		return 1
	}
	if !k.DevzoneContextSet(ctx, next) {
		fmt.Fprintf(opts.errOut(), "devzone : cannot set the devzone context on %s\n", next)
		return 1
	}
	if statePostgresOn(opts.StatePath) {
		if opts.Install == nil {
			return 1
		}
		if code := opts.Install(); code != 0 {
			return code
		}
	}
	fmt.Fprintf(opts.out(), "devzone : services cluster: %s\n", next)
	return 0
}

// statePostgresOn reports whether the postgres module is enabled.
func statePostgresOn(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "postgres=on" {
			return true
		}
	}
	return false
}
