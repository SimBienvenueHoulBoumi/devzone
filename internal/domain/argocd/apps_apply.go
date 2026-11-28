package argocd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// appsApplyOne applies one [app <name>] section from .argocd.conf.
func (m *module) appsApplyOne(name string) int {
	conf := m.conf()
	section := "app " + name
	repo := conf.Get(section, "repo")
	if repo == "" {
		fmt.Fprintf(m.errOut, "⚠ [%s] without repo in %s: skipped\n", section, m.confPath())
		return 0
	}
	path := conf.Get(section, "path")
	if path == "" {
		path = "."
	}
	revision := conf.Get(section, "revision")
	if revision == "" {
		revision = "HEAD"
	}
	namespace := conf.Get(section, "namespace")
	if namespace == "" {
		namespace = "devzone-app-" + name
	}
	username := conf.Get(section, "username")
	if username == "" {
		username = "root"
	}
	tokenFile := conf.Get(section, "token-file")
	url := appsRepoInternal(repo, m.appsGitLabNS())
	token := m.appsTokenOf(tokenFile, repo)
	if appsIsDevzoneGitLab(repo) {
		if token == "" {
			fmt.Fprintf(m.errOut, "✖ [app %s]: token of the devzone GitLab not found (workspace/.gitlab/root-token or token-file)\n", name)
			return 1
		}
		m.appsGitLabAllowArgoCD()
	}
	if token != "" {
		if code := m.appsRepoSecret(name, url, username, token); code != 0 {
			return code
		}
	}
	if code := m.gitopsApplyApplication("app-"+name, "project", namespace, url, revision, path); code != 0 {
		return code
	}
	cred := ""
	if token != "" {
		cred = "; credentials in the Secret repo-" + name
	}
	fmt.Fprintf(m.out, "✔ Application app-%s: %s (%s, %s) → namespace %s%s\n", name, url, path, revision, namespace, cred)
	return 0
}

// appsRepoSecret creates or updates the repository Secret for an app.
func (m *module) appsRepoSecret(name, url, username, token string) int {
	manifest := fmt.Sprintf("apiVersion: v1\nkind: Secret\nmetadata:\n  name: repo-%s\n  namespace: %s\n  labels:\n    argocd.argoproj.io/secret-type: repository\n    app.kubernetes.io/managed-by: devzone\ntype: Opaque\nstringData:\n  type: git\n  url: %s\n  username: %s\n  password: %s\n", name, appsNS, url, username, token)
	res, err := m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("-n", appsNS, "apply", "-f", "-"), stdinOpt(manifest))
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		}
		return 1
	}
	return 0
}

// appsGitLabAllowArgoCD patches the GitLab NetworkPolicy to allow devzone namespaces.
func (m *module) appsGitLabAllowArgoCD() {
	patch := `{"spec":{"ingress":[{"from":[{"podSelector":{},"namespaceSelector":{"matchLabels":{"app.kubernetes.io/managed-by":"devzone"}}}]}]}}`
	res, err := m.runner.Run(m.ctx, "kubectl", m.kubectlArgs("-n", m.appsGitLabNS(),
		"patch", "networkpolicy", "devzone-meme-namespace", "--type", "merge", "-p", patch), noStdin())
	if err != nil || res.Code != 0 {
		fmt.Fprintf(m.errOut, "⚠ NetworkPolicy of %s not opened to Argo CD: devzone postgres authorize %s, or the sync will fail\n", m.appsGitLabNS(), appsNS)
	}
}

// appsReconcile applies all [app] sections and removes stale project apps.
func (m *module) appsReconcile() int {
	conf := m.conf()
	declared := map[string]bool{}
	code := 0
	for _, name := range conf.Sections("app") {
		if name == "" {
			continue
		}
		declared[name] = true
		if rc := m.appsApplyOne(name); rc != 0 {
			code = 1
		}
	}
	res, err := m.kubectl("-n", appsNS, "get", "applications.argoproj.io", "-l", "devzone.io/kind=project", "-o", "name")
	if err == nil && res.Code == 0 {
		for _, line := range strings.Split(string(res.Stdout), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			app := line
			if idx := strings.LastIndex(app, "/"); idx >= 0 {
				app = app[idx+1:]
			}
			app = strings.TrimPrefix(app, "app-")
			if declared[app] {
				continue
			}
			if rc := m.appsPurge(app); rc != 0 {
				code = 1
			}
		}
	}
	return code
}

// appsPurge removes an Application, its repo Secret and devzone-managed namespace.
func (m *module) appsPurge(name string) int {
	ns := ""
	res, err := m.kubectl("-n", appsNS, "get", "application.argoproj.io", "app-"+name, "-o", "jsonpath={.spec.destination.namespace}")
	if err == nil && res.Code == 0 {
		ns = strings.TrimSpace(string(res.Stdout))
	}
	if code := m.gitopsDeleteApplication("app-"+name, "cascade"); code != 0 {
		return code
	}
	_, _ = m.kubectl("-n", appsNS, "delete", "secret", "repo-"+name, "--ignore-not-found")
	if strings.HasPrefix(ns, "devzone-app-") {
		_, _ = m.kubectl("delete", "namespace", ns, "--ignore-not-found", "--wait=true")
	}
	msg := fmt.Sprintf("✔ Application app-%s removed with its resources", name)
	if ns != "" {
		msg += fmt.Sprintf(" (namespace %s)", ns)
	}
	fmt.Fprintln(m.out, msg)
	return 0
}

// appsList lists project Applications.
func (m *module) appsList() int {
	res, err := m.kubectl("-n", appsNS, "get", "applications.argoproj.io", "-l", "devzone.io/kind=project", "-o", "custom-columns=APPLICATION:.metadata.name,REPOSITORY:.spec.source.repoURL,PATH:.spec.source.path,REVISION:.spec.source.targetRevision,NAMESPACE:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status")
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	m.out.Write(res.Stdout)
	if res.Code != 0 {
		m.errOut.Write(res.Stderr)
		return res.Code
	}
	return 0
}

// appsRemove removes an app declaration and its Application.
func (m *module) appsRemove(args []string) int {
	cmd := "devzone argocd app"
	if len(args) != 1 || !appsNameValid(args[0]) {
		fmt.Fprintf(m.errOut, "✖ %s remove <name> (%s list)\n", cmd, cmd)
		return 2
	}
	name := args[0]
	existsApp := false
	res, err := m.kubectl("-n", appsNS, "get", "application.argoproj.io", "app-"+name)
	if err == nil && res.Code == 0 {
		existsApp = true
	}
	existsConf := false
	for _, n := range m.conf().Sections("app") {
		if n == name {
			existsConf = true
			break
		}
	}
	if !existsApp && !existsConf {
		fmt.Fprintf(m.errOut, "✖ %s remove: no Application app-%s (%s list)\n", cmd, name, cmd)
		return 1
	}
	_ = m.conf().Remove("app " + name)
	_ = os.Remove(filepath.Join(m.root, "workspace", ".argocd", "tokens", name))
	return m.appsPurge(name)
}
