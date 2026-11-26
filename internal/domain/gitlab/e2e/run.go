package e2e

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// step is one timed step of the test: code 0 is a success, 2 a skipped step,
// any other code a failure. The reason is shown in the step and the summary.
type step struct {
	name string
	run  func(*session) (int, string)
}

// result is the recorded outcome of one step.
type result struct {
	name     string
	symbol   string
	duration int
	suffix   string
}

// Run runs the end-to-end test line and returns the exit status, as the shell
// entry point did: 0 without a failed step, 1 otherwise.
func Run(ctx context.Context, args []string, opts Options) int {
	if ctx == nil {
		ctx = context.Background()
	}
	full, publish, help, err := parseArgs(args)
	if err != nil {
		fmt.Fprintln(outOf(opts.Err), err)
		usage(outOf(opts.Err))
		return 2
	}
	if help {
		usage(outOf(opts.Out))
		return 0
	}
	opts.Full, opts.Publish = full, publish
	s := newSession(opts)
	s.ctx = ctx
	defer s.cleanup()

	steps := s.steps()
	results := make([]result, 0, len(steps))
	failed := false
	totalStart := s.now()
	for _, st := range steps {
		s.current = ""
		s.out("▶ %s…\n", st.name)
		start := s.now()
		code, reason := st.run(s)
		duration := int(s.now().Sub(start) / time.Second)
		if reason == "" {
			reason = s.current
		}
		r := result{name: st.name, duration: duration}
		switch code {
		case 0:
			r.symbol, r.suffix = "✔", ""
		case 2:
			r.symbol, r.suffix = "–", " — skipped: "+defaultReason(reason)
		default:
			r.symbol, r.suffix = "✖", " — "+defaultReason(reason)
			failed = true
		}
		results = append(results, r)
		s.out("  %s %s (%d s)%s\n", r.symbol, r.name, r.duration, r.suffix)
	}
	total := int(s.now().Sub(totalStart) / time.Second)
	summary(s, results, total)
	code := 0
	if failed {
		code = 1
	}
	if publish && publishStatus(s, results, total) != 0 {
		code = 1
	}
	return code
}

// defaultReason replaces an empty explanation by the shell default.
func defaultReason(reason string) string {
	if reason == "" {
		return "no reason"
	}
	return reason
}

// parseArgs reads the two options of the command; help asks for the usage.
func parseArgs(args []string) (bool, bool, bool, error) {
	full, publish, help := false, false, false
	for _, arg := range args {
		switch arg {
		case "--complet":
			full = true
		case "--statut":
			publish = true
		case "-h", "--help":
			help = true
		default:
			return false, false, false, fmt.Errorf("devzone test-gitlab : unknown option: %s", arg)
		}
	}
	return full, publish, help, nil
}

// usage writes the lines of the command help.
func usage(w io.Writer) {
	fmt.Fprintln(w, "devzone test-gitlab [--complet] [--statut]")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "End-to-end test of the gitlab module and of the GitLab platform.")
	fmt.Fprintln(w, "  --complet   disables gitlab, checks that nothing remains, then reinstalls")
	fmt.Fprintln(w, "  --statut    publishes the result as the gitlab-integration status on HEAD (gh)")
}

// steps returns the ordered steps, with step 8 first when --complet is set.
func (s *session) steps() []step {
	steps := []step{}
	if s.opts.Full {
		steps = append(steps, step{"8. full: disable", stepFull})
	}
	return append(steps,
		step{"1. module", stepModule},
		step{"2. state", stepState},
		step{"3. host name", stepName},
		step{"4. pipeline", stepPipeline},
		step{"5. HTTP and SSH clones", stepClones},
		step{"6. platform", stepPlatform},
		step{"7. repowarden integration", stepRepowarden},
	)
}

// out writes to the standard output of the run, never nil.
func (s *session) out(format string, args ...any) {
	fmt.Fprintf(outOf(s.opts.Out), format, args...)
}

// errOut writes to the standard error of the run, never nil.
func (s *session) errOut(format string, args ...any) {
	fmt.Fprintf(outOf(s.opts.Err), format, args...)
}

// reason records the explanation of the current step.
func (s *session) reason(format string, args ...any) {
	s.current = fmt.Sprintf(format, args...)
}

// outOf returns a writer that discards when none was provided.
func outOf(w io.Writer) io.Writer {
	if w == nil {
		return io.Discard
	}
	return w
}

// combined returns the standard output and error of a runner answer, as the
// shell redirection 2>&1 did.
func combined(out, errOut []byte) string {
	return strings.TrimSpace(string(out) + string(errOut))
}

// run calls a command through the runner of the session; tests replace the
// runner, so no real process is started.
func (s *session) run(name string, args []string, env ...string) (exec.Result, error) {
	if s.opts.Runner == nil {
		return exec.Result{}, fmt.Errorf("no runner for %s", name)
	}
	return s.opts.Runner.Run(s.ctx, name, args, exec.Opts{Env: env})
}
