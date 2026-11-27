package argocd

import (
	"encoding/json"
	"fmt"
	"os"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// gitlabGitopsInit creates or designates the GitLab GitOps repository and
// records it in .argocd.conf. Why: the GitOps repository lives on the GitLab
// service of the cluster, so the Argo CD controller reaches it through its
// internal service URL.
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
