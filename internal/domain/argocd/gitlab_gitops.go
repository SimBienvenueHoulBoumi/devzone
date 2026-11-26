package argocd

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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
	return "http://gitlab.localhost:8929"
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

// gitlabGitopsSHA returns the blob id of a file, or empty when absent.
func (m *module) gitlabGitopsSHA(path string) string {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		return ""
	}
	id := m.gitlabGitopsProjectID()
	if id == "" {
		return ""
	}
	encPath := strings.ReplaceAll(urlPathEscape(path), "/", "%2F")
	res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--header", "PRIVATE-TOKEN: " + token, fmt.Sprintf("%s/api/v4/projects/%s/repository/files/%s?ref=main", m.gitlabAPIURL(), id, encPath)}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	var out struct {
		BlobID string `json:"blob_id"`
	}
	if json.Unmarshal(res.Stdout, &out) != nil {
		return ""
	}
	return out.BlobID
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
	sha := m.gitlabGitopsSHA(path)
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
		}
		return 1
	}
	return 0
}

// gitlabGitopsDelete removes a file from the GitLab GitOps repository.
func (m *module) gitlabGitopsDelete(path, message string) int {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		return 0
	}
	id := m.gitlabGitopsProjectID()
	if id == "" || m.gitlabGitopsSHA(path) == "" {
		return 0
	}
	encPath := strings.ReplaceAll(urlPathEscape(path), "/", "%2F")
	res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--request", "DELETE", "--header", "PRIVATE-TOKEN: " + token, "--data-urlencode", "branch=main", "--data-urlencode", "commit_message=" + message, fmt.Sprintf("%s/api/v4/projects/%s/repository/files/%s", m.gitlabAPIURL(), id, encPath)}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		}
		return 1
	}
	return 0
}

// gitlabGitopsInit creates/designates the GitLab GitOps repository.
func (m *module) gitlabGitopsInit() int {
	token := m.gitlabGitopsRootToken()
	if token == "" {
		fmt.Fprintf(m.errOut, "✖ GitLab root token missing (%s/workspace/.gitlab/root-token): devzone enable gitlab\n", m.root)
		return 1
	}
	group := os.Getenv("GITLAB_GITOPS_GROUP")
	if group == "" {
		group = "devzone"
	}
	proj := os.Getenv("GITLAB_GITOPS_PROJECT")
	if proj == "" {
		proj = "devzone-argocd"
	}
	// ensure group
	res, _ := m.runner.Run(m.ctx, "curl", []string{"-s", "--header", "PRIVATE-TOKEN: " + token, m.gitlabAPIURL() + "/api/v4/groups/" + group}, fexec.Opts{})
	var g struct {
		ID json.Number `json:"id"`
	}
	_ = json.Unmarshal(res.Stdout, &g)
	if g.ID == "" {
		res, _ = m.runner.Run(m.ctx, "curl", []string{"-s", "--request", "POST", "--header", "PRIVATE-TOKEN: " + token, "--data-urlencode", "name=" + group, "--data-urlencode", "path=" + group, "--data", "visibility=private", m.gitlabAPIURL() + "/api/v4/groups"}, fexec.Opts{})
		_ = json.Unmarshal(res.Stdout, &g)
	}
	if g.ID == "" {
		fmt.Fprintf(m.errOut, "✖ GitLab group %s not created\n", group)
		return 1
	}
	id := m.gitlabGitopsProjectID()
	internalURL := os.Getenv("GITLAB_GITOPS_URL_INTERNE")
	if internalURL == "" {
		internalURL = "http://gitlab-webservice-default.devzone-gitlab.svc:8181/" + group + "/" + proj + ".git"
	}
	if id == "" {
		res, err := m.runner.Run(m.ctx, "curl", []string{"-s", "--request", "POST", "--header", "PRIVATE-TOKEN: " + token, "--data-urlencode", "name=" + proj, "--data", "namespace_id=" + g.ID.String(), "--data", "visibility=private", "--data", "initialize_with_readme=true", "--data-urlencode", "default_branch=main", m.gitlabAPIURL() + "/api/v4/projects"}, fexec.Opts{})
		if err != nil {
			fmt.Fprintln(m.errOut, err)
			return 1
		}
		var p struct {
			ID json.Number `json:"id"`
		}
		_ = json.Unmarshal(res.Stdout, &p)
		if p.ID == "" {
			fmt.Fprintf(m.errOut, "✖ GitLab project %s/%s not created\n", group, proj)
			return 1
		}
		fmt.Fprintf(m.out, "✔ GitOps repository created on GitLab: %s/%s (private)\n", group, proj)
		m.gitopsPutText("apps/.gitkeep", "", "devzone: apps folder")
	}
	if err := m.conf().Set("argocd", "repo="+internalURL, "provider=gitlab"); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	fmt.Fprintf(m.out, "✔ GitOps repository: GitLab %s/%s (internal URL in Argo CD)\n", group, proj)
	return 0
}
