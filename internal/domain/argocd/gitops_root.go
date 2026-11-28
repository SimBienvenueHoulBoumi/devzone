package argocd

import (
	"bytes"
	"fmt"
	"os"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// gitopsRoot creates the repository Secret and root Application.
func (m *module) gitopsRoot() int {
	if !m.gitopsEnabled() {
		return 0
	}
	url := m.gitopsRepo()
	token := os.Getenv("DEVZONE_GITOPS_TOKEN")
	user := "devzone"
	if token == "" {
		token = m.ghAuthToken()
	}
	if m.gitopsIsGitLab() {
		user = "oauth2"
		token = m.gitlabGitopsRootToken()
	}
	if token != "" {
		manifest := fmt.Sprintf("apiVersion: v1\nkind: Secret\nmetadata:\n  name: repo-%s\n  namespace: %s\n  labels:\n    argocd.argoproj.io/secret-type: repository\n    app.kubernetes.io/managed-by: devzone\ntype: Opaque\nstringData:\n  type: git\n  url: %s\n  username: %s\n  password: %s\n", gitopsRepoNameValue(), gitopsNS, url, user, token)
		res, err := m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("-n", gitopsNS, "apply", "-f", "-"), fexec.Opts{Stdin: strings.NewReader(manifest)})
		if err != nil || res.Code != 0 {
			if err != nil {
				fmt.Fprintln(m.errOut, err)
			}
			return 1
		}
	} else {
		fmt.Fprintln(m.errOut, "⚠ no GitHub token for Argo CD (gh auth token): a private repository will not sync; DEVZONE_GITOPS_TOKEN=<token>")
	}
	app, err := m.renderApp(gitopsRootApp, "root", gitopsNS, url, "HEAD", "apps")
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	res, err := m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("apply", "-f", "-"), fexec.Opts{Stdin: strings.NewReader(app)})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		}
		return 1
	}
	return 0
}

// ghAuthToken returns gh auth token or empty string.
func (m *module) ghAuthToken() string {
	res, err := m.runner.Run(m.ctx, "gh", []string{"auth", "token"}, fexec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// renderApp renders an Application manifest.
func (m *module) renderApp(name, kind, namespace, repo, revision, path string, params ...string) (string, error) {
	var b bytes.Buffer
	if err := RenderApplication(&b, name, kind, namespace, repo, revision, path, params, m.gitopsRepo()); err != nil {
		return "", err
	}
	return b.String(), nil
}

// gitopsApplyApplication writes the Application to GitOps repo or applies directly.
func (m *module) gitopsApplyApplication(name, kind, namespace, repo, revision, path string, params ...string) int {
	manifest, err := m.renderApp(name, kind, namespace, repo, revision, path, params...)
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if !m.gitopsEnabled() {
		res, err := m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("apply", "-f", "-"), fexec.Opts{Stdin: strings.NewReader(manifest)})
		if err != nil || res.Code != 0 {
			if err != nil {
				fmt.Fprintln(m.errOut, err)
			}
			return 1
		}
		return 0
	}
	tmp, err := os.CreateTemp("", "devzone-app-*")
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	tmpName := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpName)
	if err := os.WriteFile(tmpName, []byte(manifest), 0o600); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	if code := m.gitopsPut("apps/"+name+".yaml", tmpName, "devzone: application "+name); code != 0 {
		return code
	}
	m.gitopsRefresh()
	return 0
}

// gitopsDirectDeleteApplication deletes an Application from the cluster.
func (m *module) gitopsDirectDeleteApplication(name, mode string) int {
	if mode == "keep" {
		_, _ = m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("-n", gitopsNS, "patch", "application.argoproj.io",
			name, "--type", "merge", "-p", `{"metadata":{"finalizers":null}}`), fexec.Opts{})
	}
	res, err := m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("-n", gitopsNS, "delete", "application.argoproj.io",
		name, "--ignore-not-found", "--wait=true"), fexec.Opts{})
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		}
		return 1
	}
	return 0
}

// gitopsDeleteApplication removes the Application file from Git then deletes it.
func (m *module) gitopsDeleteApplication(name, mode string) int {
	if m.gitopsEnabled() {
		if code := m.gitopsDelete("apps/"+name+".yaml", "devzone: application "+name+" removed"); code != 0 {
			return code
		}
		m.gitopsRefresh()
	}
	return m.gitopsDirectDeleteApplication(name, mode)
}
