package podcmd

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// repairCall is one repair step: a name for the report, the pod command to run
// and the extra environment it needs, as in the removed shell function.
type repairCall struct {
	name string
	args []string
	env  []string
}

// runRepair repairs the active services, the catalog watcher and the grouped
// credentials, reporting each item and returning 1 when one step failed.
func runRepair(ctx *cli.Context) int {
	script, err := podScript()
	if err != nil {
		fmt.Fprintln(ctx.Err, err)
		return 1
	}
	st := state.At(statePath())
	calls := []repairCall{}
	if st.Get("gitlab") == "on" {
		calls = append(calls,
			repairCall{name: "gitlab name", args: []string{"gitlab", "host-set"}},
			repairCall{name: "gitlab relay", args: []string{"gitlab", "relay-start"}})
	}
	if st.Get("postgres") == "on" {
		calls = append(calls, repairCall{name: "postgres relay", args: []string{"postgres", "relay-start"}})
	}
	if st.Get("argocd") == "on" {
		calls = append(calls, repairCall{name: "argocd relay", args: []string{"argocd", "relay-start"}})
	}
	if st.Get("mysql") == "on" {
		calls = append(calls, repairCall{name: "mysql relay", args: []string{"mysql", "relay-start"}})
	}
	calls = append(calls,
		repairCall{
			name: "catalog watcher",
			args: []string{"catalog-watcher", "start"},
			env:  []string{"DEVZONE_STATE=" + statePath(), "DEVZONE_CATALOG_REAL=yes"},
		},
		repairCall{name: "credentials", args: []string{"passwords", "regenerate"}})
	failed := 0
	for _, call := range calls {
		if !runRepairCall(ctx, script, call) {
			failed = 1
		}
	}
	repairClusterClean(ctx, script)
	return failed
}

// runRepairCall executes one repair step and prints its ✓ or ✖ line, using the
// last non-empty output line as the reason when the step failed.
func runRepairCall(ctx *cli.Context, script string, call repairCall) bool {
	res, err := ctx.Runner.Run(context.Background(), script, call.args, exec.Opts{Env: call.env})
	if err == nil && res.Code == 0 {
		fmt.Fprintf(ctx.Out, "✔ %s\n", call.name)
		return true
	}
	code := res.Code
	if err != nil {
		code = 1
	}
	reason := lastOutputLine(string(res.Stdout) + string(res.Stderr))
	if reason == "" {
		reason = fmt.Sprintf("failed (code %d)", code)
	}
	fmt.Fprintf(ctx.Out, "✖ %s : %s\n", call.name, reason)
	return false
}

// lastOutputLine returns the last non-blank line of a command output, the same
// reason the shell report extracted from its captured output.
func lastOutputLine(output string) string {
	lines := strings.Split(output, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if line := strings.TrimSpace(lines[i]); line != "" {
			return line
		}
	}
	return ""
}

// repairClusterClean removes the stale contexts after the repairs; its result
// never fails the command, like the shell call it replaces.
func repairClusterClean(ctx *cli.Context, script string) {
	res, err := ctx.Runner.Run(context.Background(), script, []string{"cluster", "clean"}, exec.Opts{})
	if err != nil {
		return
	}
	if len(res.Stdout) > 0 {
		_, _ = io.WriteString(ctx.Out, string(res.Stdout))
	}
	if len(res.Stderr) > 0 {
		_, _ = io.WriteString(ctx.Err, string(res.Stderr))
	}
}
