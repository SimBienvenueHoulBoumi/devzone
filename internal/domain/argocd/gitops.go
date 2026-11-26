package argocd

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

const (
	gitopsNS       = "devzone-argocd"
	gitopsRootApp  = "devzone"
	gitopsRepoName = "devzone-argocd"
)

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
	name := os.Getenv("DEVZONE_GITOPS_REPO_NAME")
	if name == "" {
		name = gitopsRepoName
	}
	slug := login + "/" + name
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

// gitopsPutText writes a text file to the GitOps repository.
func (m *module) gitopsPutText(path, content, message string) int {
	tmp, err := os.CreateTemp("", "devzone-gitops-*")
	if err != nil {
		return 1
	}
	name := tmp.Name()
	tmp.Close()
	defer os.Remove(name)
	if err := os.WriteFile(name, []byte(content), 0o600); err != nil {
		return 1
	}
	return m.gitopsPut(path, name, message)
}

// gitopsSHA returns the blob sha of a file in the repo, or empty when absent.
func (m *module) gitopsSHA(path string) string {
	if m.gitopsIsGitLab() {
		return m.gitlabGitopsSHA(path)
	}
	res, err := m.runner.Run(m.ctx, "gh", []string{"api", "repos/" + m.gitopsSlug() + "/contents/" + path, "--jq", ".sha"}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	out := strings.TrimSpace(string(res.Stdout))
	for _, c := range out {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return ""
		}
	}
	return out
}

// gitopsPut writes file at path in the repo, skipping when the blob sha matches.
func (m *module) gitopsPut(path, file, message string) int {
	if m.gitopsIsGitLab() {
		return m.gitlabGitopsPut(path, file, message)
	}
	slug := m.gitopsSlug()
	sha := m.gitopsSHA(path)
	if sha != "" {
		if blob, err := gitHashObject(file); err == nil && blob == sha {
			return 0
		}
	}
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	content := base64.StdEncoding.EncodeToString(data)
	args := []string{"api", "-X", "PUT", "repos/" + slug + "/contents/" + path, "-f", "message=" + message, "-f", "content=" + content}
	if sha != "" {
		args = append(args, "-f", "sha="+sha)
	}
	res, err := m.runner.Run(m.ctx, "gh", args, fexec.Opts{})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		} else {
			m.errOut.Write(res.Stderr)
			m.errOut.Write(res.Stdout)
		}
		return 1
	}
	return 0
}

// gitHashObject returns the git blob sha for a file, matching `git hash-object`.
func gitHashObject(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	// blob sha: sha1("blob <len>\x00" + content)
	return gitBlobSHA(data), nil
}

// gitopsDelete removes a file from the repo when it exists.
func (m *module) gitopsDelete(path, message string) int {
	if m.gitopsIsGitLab() {
		return m.gitlabGitopsDelete(path, message)
	}
	sha := m.gitopsSHA(path)
	if sha == "" {
		return 0
	}
	res, err := m.runner.Run(m.ctx, "gh", []string{"api", "-X", "DELETE", "repos/" + m.gitopsSlug() + "/contents/" + path, "-f", "message=" + message, "-f", "sha=" + sha}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		}
		return 1
	}
	return 0
}

// gitopsRefresh annotates the root Application to trigger an immediate refresh.
func (m *module) gitopsRefresh() {
	_, _ = m.kubectl("-n", gitopsNS, "annotate", "application.argoproj.io", gitopsRootApp, "argocd.argoproj.io/refresh=normal", "--overwrite")
}
