package argocd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

const (
	gitopsNS       = config.NamespaceArgoCD
	gitopsRootApp  = "devzone"
	gitopsRepoName = "devzone-argocd"
)

// gitopsRepoNameValue returns the name of the GitOps repository and of its
// Secret: DEVZONE_GITOPS_REPO_NAME when set, devzone-argocd otherwise. Both
// places must agree, or the Secret would point at another name than the one
// created on GitHub.
func gitopsRepoNameValue() string {
	if name := os.Getenv("DEVZONE_GITOPS_REPO_NAME"); name != "" {
		return name
	}
	return gitopsRepoName
}

// conf returns the .argocd.conf handle for this module.
func (m *module) conf() Conf { return Conf{Path: m.confPath()} }

// confPath returns the path to .argocd.conf.
func (m *module) confPath() string {
	if p := os.Getenv("DEVZONE_ARGOCD_CONF"); p != "" {
		return p
	}
	return filepath.Join(m.root, ".argocd.conf")
}

// gitopsRepo returns the configured GitOps repository URL.
func (m *module) gitopsRepo() string { return m.conf().Get("argocd", "repo") }

// gitopsEnabled reports whether a GitOps repository is designated.
func (m *module) gitopsEnabled() bool {
	r := m.gitopsRepo()
	return r != "" && r != "none"
}

// gitopsIsGitLab reports whether the GitOps repository is hosted on GitLab.
func (m *module) gitopsIsGitLab() bool { return m.conf().Get("argocd", "provider") == "gitlab" }

// gitopsSlug returns owner/name for a GitHub repository.
func (m *module) gitopsSlug() string {
	r := m.gitopsRepo()
	r = strings.TrimPrefix(r, "https://github.com/")
	return strings.TrimSuffix(r, ".git")
}

// gitopsInit implements "init [--repo ...|--none|--gitlab]".
func (m *module) gitopsInit(args []string) int {
	repo := ""
	expect := ""
	for _, arg := range args {
		if expect == "repo" {
			repo = arg
			expect = ""
			continue
		}
		switch arg {
		case "--gitlab":
			return m.gitlabGitopsInit()
		case "--none":
			if err := m.conf().Set("argocd", "repo=none"); err != nil {
				fmt.Fprintln(m.errOut, err)
				return 1
			}
			fmt.Fprintln(m.out, "✔ no GitOps repository: the Applications are applied directly (devzone argocd init to change)")
			return 0
		case "--repo":
			expect = "repo"
		default:
			fmt.Fprintln(m.errOut, "✖ devzone argocd init [--repo https://github.com/<owner>/<name>.git] [--none]")
			return 2
		}
	}
	if expect != "" {
		fmt.Fprintln(m.errOut, "✖ --repo needs a URL")
		return 2
	}
	if repo != "" {
		return m.gitopsInitRepo(repo)
	}
	if m.gitopsEnabled() {
		return 0
	}
	if !m.ghAuthOK() {
		fmt.Fprintln(m.out, "ℹ GitHub not connected (gh auth login): no GitOps repository, the Applications are applied directly; devzone argocd init --none to stop this notice")
		return 0
	}
	login := m.ghLogin()
	if login == "" {
		fmt.Fprintln(m.errOut, "⚠ GitHub login unreadable (gh api user): Applications applied directly")
		return 0
	}
	slug := login + "/" + gitopsRepoNameValue()
	if !m.ghRepoExists(slug) {
		if !m.ghRepoCreate(slug) {
			fmt.Fprintf(m.errOut, "✖ cannot create the GitOps repository %s\n", slug)
			return 1
		}
		fmt.Fprintf(m.out, "✔ GitOps repository created: https://github.com/%s (private)\n", slug)
	}
	if err := m.conf().Set("argocd", "repo=https://github.com/"+slug+".git"); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	m.gitopsPutText("README.md", "# devzone-argocd\n\nGitOps repository of devzone, written by the devzone commands (never by hand): the Argo CD of devzone follows the apps/ folder, one Application per file (the workspace, the services, the projects added with argocd app add). Removing a file removes the Application and its resources.\n", "devzone: GitOps repository")
	m.gitopsPutText("apps/.gitkeep", "", "devzone: apps folder")
	return 0
}

// gitopsInitRepo handles init with an explicit --repo URL.
func (m *module) gitopsInitRepo(repo string) int {
	if !strings.HasPrefix(repo, "https://github.com/") || strings.Count(strings.TrimPrefix(repo, "https://github.com/"), "/") < 1 {
		fmt.Fprintf(m.errOut, "✖ GitHub repository URL expected (https://github.com/<owner>/<name>.git): %s\n", repo)
		return 2
	}
	slug := strings.TrimSuffix(strings.TrimPrefix(repo, "https://github.com/"), ".git")
	if m.ghAuthOK() && !m.ghRepoExists(slug) {
		if !m.ghRepoCreate(slug) {
			fmt.Fprintf(m.errOut, "✖ cannot create the GitOps repository %s\n", slug)
			return 1
		}
		fmt.Fprintf(m.out, "✔ GitOps repository created: https://github.com/%s (private)\n", slug)
		if err := m.conf().Set("argocd", "repo="+repo); err != nil {
			fmt.Fprintln(m.errOut, err)
			return 1
		}
		m.gitopsPutText("README.md", "# devzone-argocd\n\nGitOps repository of devzone, written by the devzone commands (never by hand): the Argo CD of devzone follows the apps/ folder, one Application per file (the workspace, the services, the projects added with argocd app add). Removing a file removes the Application and its resources.\n", "devzone: GitOps repository")
		m.gitopsPutText("apps/.gitkeep", "", "devzone: apps folder")
		return 0
	}
	if err := m.conf().Set("argocd", "repo="+repo); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	fmt.Fprintf(m.out, "✔ GitOps repository: %s (%s)\n", repo, m.confPath())
	return 0
}

// ghAuthOK reports whether gh is authenticated.
func (m *module) ghAuthOK() bool {
	res, err := m.runner.Run(m.ctx, "gh", []string{"auth", "status"}, fexec.Opts{})
	return err == nil && res.Code == 0
}

// ghLogin returns the GitHub login or empty string.
func (m *module) ghLogin() string {
	res, err := m.runner.Run(m.ctx, "gh", []string{"api", "user", "--jq", ".login"}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// ghRepoExists reports whether owner/repo exists on GitHub.
func (m *module) ghRepoExists(slug string) bool {
	res, err := m.runner.Run(m.ctx, "gh", []string{"repo", "view", slug, "--json", "name"}, fexec.Opts{})
	return err == nil && res.Code == 0
}

// ghRepoCreate creates a private GitHub repository.
func (m *module) ghRepoCreate(slug string) bool {
	res, err := m.runner.Run(m.ctx, "gh", []string{"repo", "create", slug, "--private", "--description", "GitOps repository of devzone: the Applications Argo CD holds (workspace, services, projects)"}, fexec.Opts{})
	return err == nil && res.Code == 0
}
