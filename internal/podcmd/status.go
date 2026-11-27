package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// runStatus prints the summary of a devzone instance, or its JSON form with
// --json; it replaces the removed shell status library without a shell fallback.
func runStatus(ctx *cli.Context) int {
	if len(ctx.Args) > 0 && ctx.Args[0] == "--json" {
		return runStateJSON(ctx, state.At(statePath()))
	}
	st := state.At(statePath())
	d := jsonDeps{ctx: ctx, st: st, root: devzoneRoot(), code: codeRoot()}
	fmt.Fprintln(ctx.Out, "devzone: state (devzone to show it again)")
	versionAvailableLine(ctx)
	printGitIdentity(ctx, d)
	printPlatform(ctx, d)
	printOutdatedTools(ctx)
	printMissingWorktrees(ctx)
	printModules(ctx, d)
	printStatusDetails(ctx, d)
	return 0
}

// statusCapture runs one Go command into a buffer with the caller's runner so
// the summary reuses the state helpers without starting a shell.
func statusCapture(ctx *cli.Context, args []string, run func(*cli.Context) int) (string, int) {
	var out, errOut strings.Builder
	sub := &cli.Context{Args: args, Out: &out, Err: &errOut, Stdin: ctx.Stdin, Runner: ctx.Runner}
	code := run(sub)
	return out.String(), code
}

// printGitIdentity reports the configured git identity, or the two commands
// needed to set it, exactly as the former status function did.
func printGitIdentity(ctx *cli.Context, d jsonDeps) {
	name, _, _ := d.run("git", "config", "--get", "user.name")
	email, _, _ := d.run("git", "config", "--get", "user.email")
	name, email = trimNewlines(name), trimNewlines(email)
	if name != "" && email != "" {
		fmt.Fprintf(ctx.Out, "  ✔ git identity    %s <%s>\n", name, email)
		return
	}
	fmt.Fprintln(ctx.Out, "  ✖ git identity    needed to commit: gh auth login -s workflow (automatic),")
	fmt.Fprintln(ctx.Out, "                    or git config --file ~/.config/git/config user.name \"<name>\" and user.email \"<email>\"")
}

// printPlatform reports the chosen platform and the GitHub connection state.
func printPlatform(ctx *cli.Context, d jsonDeps) {
	if d.st.Get("platform") == "gitlab" {
		url := d.st.Get("gitlab_url")
		host := gitlabHost(url)
		glab := filepath.Join(os.Getenv("HOME"), ".local", "bin", "glab")
		_, code, err := d.run(glab, "auth", "status", "--hostname", host)
		if err == nil && code == 0 {
			fmt.Fprintf(ctx.Out, "  ✔ platform       gitlab: %s, glab connected\n", url)
		} else {
			fmt.Fprintf(ctx.Out, "  ⚠ platform       gitlab: %s, glab not connected: glab auth login --hostname %s\n", url, host)
		}
		fmt.Fprintln(ctx.Out, "  ○ GitHub          not needed here (gitlab platform chosen)")
		fmt.Fprintln(ctx.Out, "  ⚠ repowarden      stays on GitHub (bots and tickets): GitLab support coming (simdevWarden/repowarden#531)")
		return
	}
	fmt.Fprintln(ctx.Out, "  ✔ platform       github")
	out, code, err := d.runBoth("gh", "auth", "status")
	switch {
	case err != nil || code != 0:
		fmt.Fprintln(ctx.Out, "  ○ GitHub          optional (push and PR, repowarden tickets) : gh auth login -s workflow")
	case strings.Contains(out, "Token scopes:") && !strings.Contains(out, "'workflow'"):
		fmt.Fprintln(ctx.Out, "  ⚠ GitHub          connected, without workflow permission (push of .github/workflows/ refused): gh auth refresh -h github.com -s workflow")
	default:
		fmt.Fprintln(ctx.Out, "  ✔ GitHub          connected")
	}
}

// gitlabHost strips the protocol and the trailing slash of a GitLab URL, like
// the host_of helper of the removed platform library.
func gitlabHost(url string) string {
	if i := strings.Index(url, "://"); i >= 0 {
		url = url[i+3:]
	}
	return strings.TrimSuffix(url, "/")
}

// printOutdatedTools reports the tools installed at a version different from
// the pinned one, or the pinned-version line when the state helper succeeds.
func printOutdatedTools(ctx *cli.Context) {
	out, code := statusCapture(ctx, []string{"outdated-tools"}, runStateOutdatedTools)
	if code != 0 {
		return
	}
	lines := strings.Split(out, "\n")
	late := false
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		late = true
		pinned, installed := "", ""
		if len(fields) > 1 {
			pinned = fields[1]
		}
		if len(fields) > 2 {
			installed = fields[2]
		}
		fmt.Fprintf(ctx.Out, "  ⚠ tools          %s %s installed, %s pinned: devzone apply\n", fields[0], installed, pinned)
	}
	if !late {
		fmt.Fprintln(ctx.Out, "  ✔ tools          pinned versions")
	}
}

// printMissingWorktrees warns about worktrees registered in a local repository
// but absent from this instance, without changing any repository.
func printMissingWorktrees(ctx *cli.Context) {
	out, _ := statusCapture(ctx, []string{"missing-worktrees"}, runStateMissingWorktrees)
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fmt.Fprintf(ctx.Out, "  ⚠ worktree        %s absent here (created outside the container?): manage it on that side, never git worktree prune here (manage/docs/reference.md, Git worktrees)\n", line)
	}
}
