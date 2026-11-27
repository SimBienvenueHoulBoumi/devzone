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
// The second return is false when the host refused the read for a reason other
// than the file being missing: a caller must then stop, as the old shell did
// with "|| return 1", instead of treating the failure as "not found".
func (m *module) gitopsSHA(path string) (string, bool) {
	if m.gitopsIsGitLab() {
		return m.gitlabGitopsSHA(path)
	}
	res, err := m.runner.Run(m.ctx, "gh", []string{"api", "repos/" + m.gitopsSlug() + "/contents/" + path, "--jq", ".sha"}, fexec.Opts{})
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return "", false
	}
	if res.Code != 0 {
		if gitopsNotFound(res) {
			return "", true
		}
		m.errOut.Write(res.Stderr)
		m.errOut.Write(res.Stdout)
		return "", false
	}
	out := strings.TrimSpace(string(res.Stdout))
	for _, c := range out {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return "", true
		}
	}
	return out, true
}

// gitopsNotFound reports whether a failed GitHub contents read means the file
// is absent (HTTP 404), which is the only failure a delete may ignore.
func gitopsNotFound(res fexec.Result) bool {
	msg := strings.ToLower(string(res.Stdout) + string(res.Stderr))
	return strings.Contains(msg, "404") || strings.Contains(msg, "not found")
}

// gitopsPut writes file at path in the repo, skipping when the blob sha matches.
func (m *module) gitopsPut(path, file, message string) int {
	if m.gitopsIsGitLab() {
		return m.gitlabGitopsPut(path, file, message)
	}
	slug := m.gitopsSlug()
	sha, ok := m.gitopsSHA(path)
	if !ok {
		return 1
	}
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

// gitopsDelete removes a file from the repo when it exists. A read failure
// that is not "file absent" is returned to the caller: the old shell did
// "sha=$(... || return 1)", so a refused GitHub API must stop the stop.
func (m *module) gitopsDelete(path, message string) int {
	if m.gitopsIsGitLab() {
		return m.gitlabGitopsDelete(path, message)
	}
	sha, ok := m.gitopsSHA(path)
	if !ok {
		return 1
	}
	if sha == "" {
		return 0
	}
	res, err := m.runner.Run(m.ctx, "gh", []string{"api", "-X", "DELETE", "repos/" + m.gitopsSlug() + "/contents/" + path, "-f", "message=" + message, "-f", "sha=" + sha}, fexec.Opts{})
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

// gitopsRefresh annotates the root Application to trigger an immediate refresh.
func (m *module) gitopsRefresh() {
	_, _ = m.kubectl("-n", gitopsNS, "annotate", "application.argoproj.io", gitopsRootApp, "argocd.argoproj.io/refresh=normal", "--overwrite")
}
