package create

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// gitopsValue resolves the GitOps repository of Argo CD (#539): github maps to
// a repository under the gh account, none applies directly, anything else is a
// URL; gh is called through the runner and never receives credentials.
func gitopsValue(gitops string, opts Options) string {
	if gitops == "none" {
		return "none"
	}
	if gitops != "github" {
		return gitops
	}
	if res, err := opts.Runner.Run(opts.Ctx, "gh", []string{"auth", "status"}, fexec.Opts{}); err != nil || res.Code != 0 {
		fmt.Fprintln(opts.Err, "⚠ GitHub not connected (gh auth login): no GitOps repository, the Applications are applied directly; pass --gitops none")
		return "none"
	}
	res, err := opts.Runner.Run(opts.Ctx, "gh", []string{"api", "user", "--jq", ".login"}, fexec.Opts{})
	login := ""
	if err == nil && res.Code == 0 {
		login = strings.TrimSpace(string(res.Stdout))
	}
	if login == "" {
		fmt.Fprintln(opts.Err, "⚠ GitHub login unreadable (gh api user): no GitOps repository, the Applications are applied directly; pass --gitops none")
		return "none"
	}
	name := os.Getenv("DEVZONE_GITOPS_REPO_NAME")
	if name == "" {
		name = "devzone-argocd"
	}
	instance := os.Getenv("DEVZONE_VOLUMES")
	if instance == "" {
		instance = "devzone"
	}
	if instance != "devzone" {
		name = name + "-" + instance
	}
	return "https://github.com/" + login + "/" + name + ".git"
}

// askGitops asks on a terminal which GitOps repository to use (#539): empty
// answer takes the default, github when gh is connected; G/y forms mean
// github, n forms mean none, anything else is a URL.
func askGitops(in io.Reader, errOut io.Writer, runner fexec.Runner, ctx context.Context) string {
	defaultValue := ""
	if res, err := runner.Run(ctx, "gh", []string{"auth", "status"}, fexec.Opts{}); err == nil && res.Code == 0 {
		defaultValue = "github"
	}
	fmt.Fprint(errOut, "GitOps repository for Argo CD? [G]itHub (created under your gh account at first start) / a URL / [n]one : ")
	answer := readLine(in)
	if answer == "" {
		answer = defaultValue
	}
	switch answer {
	case "G", "g", "GitHub", "github", "y", "Y", "yes":
		return "github"
	case "n", "N", "none", "None":
		return "none"
	}
	return answer
}

// readLine reads one line; end of input gives an empty answer, including a
// partial line at end of input, as `read -r answer || answer=""` does.
func readLine(in io.Reader) string {
	var line []byte
	buf := make([]byte, 1)
	for {
		n, err := in.Read(buf)
		if n > 0 {
			if buf[0] == '\n' {
				return strings.TrimSuffix(string(line), "\r")
			}
			line = append(line, buf[0])
		}
		if err != nil {
			return ""
		}
	}
}
