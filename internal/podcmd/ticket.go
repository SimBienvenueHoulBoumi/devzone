package podcmd

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"os/exec"
	"path/filepath"
	"strings"
)

// runTicket is the devzone ticket command: parse, then start or done.
func runTicket(ctx *cli.Context) int {
	args := ctx.Args
	out := ctx.Out
	errOut := ctx.Err
	req, err := parseTicket(args)
	if err == errTicketUsage {
		fmt.Fprintln(errOut, "usage: devzone ticket <n> [--repo devzone|repowarden]")
		fmt.Fprintln(errOut, "       devzone ticket done <n> [--repo devzone|repowarden]")
		return 1
	}

	clone, wt, err := ticketPaths(ticketEnvFromOS(), req.repo, req.n)
	if refusal, ok := err.(ticketRefusal); ok {
		fmt.Fprintf(errOut, "devzone ticket: %s\n", refusal.Error())
		return 2
	}

	if req.done {
		return ticketDone(clone, wt, req.n, out, errOut)
	}
	return ticketStart(clone, wt, req.n, out, errOut)
}

// gitCmd runs git -C dir with args, returning its trimmed standard output and exit code.
// Standard error goes to errOut; a command that cannot start returns status 127.
func gitCmd(dir string, errOut io.Writer, args ...string) (string, int) {
	cmdArgs := append([]string{"-C", dir}, args...)
	cmd := exec.Command("git", cmdArgs...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = errOut
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return strings.TrimSpace(buf.String()), exitErr.ExitCode()
		}
		fmt.Fprintf(errOut, "devzone ticket: git: %v\n", err)
		return strings.TrimSpace(buf.String()), 127
	}
	return strings.TrimSpace(buf.String()), 0
}

// ticketStart creates the worktree of a ticket and launches repowarden ticket there.
func ticketStart(clone, wt, n string, out, errOut io.Writer) int {
	if _, err := os.Stat(wt); err == nil {
		fmt.Fprintf(out, "worktree already there: %s\n", wt)
		fmt.Fprintln(out, wt)
		return 0
	}

	if _, code := gitCmd(clone, errOut, "fetch", "--quiet", "origin"); code != 0 {
		return code
	}
	if err := os.MkdirAll(filepath.Dir(wt), 0o755); err != nil {
		fmt.Fprintf(errOut, "devzone ticket: %v\n", err)
		return 1
	}
	if _, code := gitCmd(clone, errOut, "worktree", "add", "--quiet", "--detach", wt, "origin/develop"); code != 0 {
		return code
	}

	cmd := exec.Command("repowarden", "ticket", n)
	cmd.Dir = wt
	cmd.Stdout = out
	cmd.Stderr = errOut
	if err := cmd.Run(); err != nil {
		gitCmd(clone, errOut, "worktree", "remove", "--force", wt)
		fmt.Fprintf(errOut, "devzone ticket: repowarden ticket %s failed, worktree removed\n", n)
		return 2
	}

	branch, code := gitCmd(wt, errOut, "branch", "--show-current")
	if code != 0 {
		return code
	}
	if branch == "" {
		branch = "none"
	}
	fmt.Fprintf(out, "ticket #%s: branch %s\n", n, branch)
	fmt.Fprintln(out, wt)
	return 0
}

// ticketDone removes the worktree and local branch of a ticket once the work is merged.
func ticketDone(clone, wt, n string, out, errOut io.Writer) int {
	fi, err := os.Stat(wt)
	if err != nil || !fi.IsDir() {
		fmt.Fprintf(errOut, "devzone ticket: no worktree for ticket %s: %s\n", n, wt)
		return 2
	}

	porcelain, _ := gitCmd(wt, errOut, "status", "--porcelain")
	if porcelain != "" {
		fmt.Fprintf(errOut, "devzone ticket: worktree %s is not clean, commit or discard first\n", wt)
		return 2
	}

	branch, code := gitCmd(wt, errOut, "branch", "--show-current")
	if code != 0 {
		return code
	}
	if branch != "" {
		if _, code := gitCmd(clone, io.Discard, "ls-remote", "--exit-code", "--heads", "origin", branch); code == 0 {
			fmt.Fprintf(errOut, "devzone ticket: branch %s still exists on origin: merge the pull request first\n", branch)
			return 2
		}
	}

	if _, code := gitCmd(clone, errOut, "worktree", "remove", wt); code != 0 {
		return code
	}
	if branch != "" {
		gitCmd(clone, errOut, "branch", "-D", branch)
	}

	shown := branch
	if shown == "" {
		shown = "none"
	}
	fmt.Fprintf(out, "ticket #%s: worktree %s and local branch %s removed\n", n, wt, shown)
	return 0
}
