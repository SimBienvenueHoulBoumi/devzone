package argocd

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// gitlabGitopsRootToken returns the GitLab root token for Argo CD access.
func (m *module) gitlabGitopsRootToken() string {
	file := filepath.Join(m.root, "workspace", ".gitlab", "root-token")
	data, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// gitlabAPIURL returns the GitLab API base URL.
func (m *module) gitlabAPIURL() string {
	if v := os.Getenv("GITLAB_GITOPS_API"); v != "" {
		return v
	}
	return config.GitLab().WebURL()
}

// gitlabGitopsProject returns the GitLab project path (group/project).
func (m *module) gitlabGitopsProject() string {
	group := os.Getenv("GITLAB_GITOPS_GROUP")
	if group == "" {
		group = "devzone"
	}
	proj := os.Getenv("GITLAB_GITOPS_PROJECT")
	if proj == "" {
		proj = "devzone-argocd"
	}
	return group + "%2F" + proj
}

// gitlabGitopsProjectID returns the numeric project id or empty string.
func (m *module) gitlabGitopsProjectID() string {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		return ""
	}
	res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--header", "PRIVATE-TOKEN: " + token, m.gitlabAPIURL() + "/api/v4/projects/" + m.gitlabGitopsProject()}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	var out struct {
		ID json.Number `json:"id"`
	}
	if json.Unmarshal(res.Stdout, &out) != nil || out.ID == "" {
		return ""
	}
	return out.ID.String()
}

// gitlabGitopsSHA returns the blob id of a file, or empty when absent. The
// second return is false when the host refused the read for a reason other than
// "file missing", so callers stop instead of ignoring the failure.
func (m *module) gitlabGitopsSHA(path string) (string, bool) {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		return "", false
	}
	id := m.gitlabGitopsProjectID()
	if id == "" {
		return "", false
	}
	encPath := strings.ReplaceAll(urlPathEscape(path), "/", "%2F")
	res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--header", "PRIVATE-TOKEN: " + token, fmt.Sprintf("%s/api/v4/projects/%s/repository/files/%s?ref=main", m.gitlabAPIURL(), id, encPath)}, fexec.Opts{})
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return "", false
	}
	if res.Code != 0 {
		if gitopsNotFound(res) || len(strings.TrimSpace(string(res.Stdout)+string(res.Stderr))) == 0 {
			return "", true
		}
		m.errOut.Write(res.Stderr)
		m.errOut.Write(res.Stdout)
		return "", false
	}
	var out struct {
		BlobID  string `json:"blob_id"`
		Message string `json:"message"`
	}
	if json.Unmarshal(res.Stdout, &out) != nil {
		if gitopsNotFound(res) {
			return "", true
		}
		m.errOut.Write(res.Stdout)
		return "", false
	}
	if out.BlobID == "" && strings.Contains(strings.ToLower(out.Message), "not found") {
		return "", true
	}
	return out.BlobID, true
}

// urlPathEscape escapes a path for GitLab files API.
func urlPathEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// gitlabGitopsPut creates or updates a file in the GitLab GitOps repository.
func (m *module) gitlabGitopsPut(path, file, message string) int {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		fmt.Fprintf(m.errOut, "✖ GitLab root token missing (%s/workspace/.gitlab/root-token): devzone enable gitlab\n", m.root)
		return 1
	}
	id := m.gitlabGitopsProjectID()
	if id == "" {
		fmt.Fprintln(m.errOut, "✖ GitLab project devzone/devzone-argocd missing: devzone argocd init --gitlab")
		return 1
	}
	sha, ok := m.gitlabGitopsSHA(path)
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
	verb := "POST"
	if sha != "" {
		verb = "PUT"
	}
	encPath := strings.ReplaceAll(urlPathEscape(path), "/", "%2F")
	res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--request", verb, "--header", "PRIVATE-TOKEN: " + token, "--data-urlencode", "branch=main", "--data-urlencode", "encoding=base64", "--data-urlencode", "content=" + content, "--data-urlencode", "commit_message=" + message, fmt.Sprintf("%s/api/v4/projects/%s/repository/files/%s", m.gitlabAPIURL(), id, encPath)}, fexec.Opts{})
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

// gitlabGitopsDelete removes a file from the GitLab GitOps repository. A read
// failure that is not "file absent" is returned, like the GitHub path.
func (m *module) gitlabGitopsDelete(path, message string) int {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		return 0
	}
	id := m.gitlabGitopsProjectID()
	if id == "" {
		return 0
	}
	sha, ok := m.gitlabGitopsSHA(path)
	if !ok {
		return 1
	}
	if sha == "" {
		return 0
	}
	encPath := strings.ReplaceAll(urlPathEscape(path), "/", "%2F")
	res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--request", "DELETE", "--header", "PRIVATE-TOKEN: " + token, "--data-urlencode", "branch=main", "--data-urlencode", "commit_message=" + message, fmt.Sprintf("%s/api/v4/projects/%s/repository/files/%s", m.gitlabAPIURL(), id, encPath)}, fexec.Opts{})
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
