package argocd

import (
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

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
