package gitlab

import (
	"fmt"
	"os"
	"strings"
)

// repoURL is the default GitOps repository URL of the Applications
// (catalogue_argocd_load of catalog-argocd.sh, DEVZONE_REPO_URL).
func (r *run) repoURL() string {
	if url := os.Getenv("DEVZONE_REPO_URL"); url != "" {
		return url
	}
	return "https://github.com/SimBienvenueHoulBoumi/devzone.git"
}

// stateValue returns the value of key in the state of the instance
// (the last line key=... of the state file, cluster.sh cluster_saved style).
func (r *run) stateValue(key string) string {
	data, err := os.ReadFile(r.state)
	if err != nil {
		return ""
	}
	value := ""
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, key+"="); ok {
			value = v
		}
	}
	return value
}

// argocdRevision returns DEVZONE_ARGOCD_REVISION or the v-tag of package.json
// (empty on a development clone, version 0.0.0) (argocd_revision of
// catalog-argocd.sh).
func (r *run) argocdRevision() string {
	if v := os.Getenv("DEVZONE_ARGOCD_REVISION"); v != "" {
		return v
	}
	data, err := os.ReadFile(r.root + "/package.json")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		i := strings.Index(strings.TrimSpace(line), `"version":`)
		if i < 0 {
			continue
		}
		v := strings.TrimSpace(strings.TrimSpace(line)[i+len(`"version":`):])
		if !strings.HasPrefix(v, `"`) {
			continue
		}
		if end := strings.IndexByte(v[1:], '"'); end >= 0 {
			version := v[1 : 1+end]
			if version == "" || version == "0.0.0" {
				return ""
			}
			return "v" + version
		}
	}
	return ""
}

// argocdActive reports whether the Application devzone-gitlab can be used:
// the module argocd is on, the chart is in the repository, the namespace
// devzone-argocd answers kubectl and the revision is known (argocd.sh
// gitlab_argocd_active → catalogue_argocd_active gitlab).
func (r *run) argocdActive() bool {
	if r.stateValue("argocd") != "on" {
		return false
	}
	if _, err := os.Stat(r.root + "/charts/devzone-gitlab"); err != nil {
		return false
	}
	res, err := r.kubectlAdmin([]string{"get", "namespace", "devzone-argocd"})
	if err != nil || res.Code != 0 {
		return false
	}
	return r.argocdRevision() != ""
}

// releaseAdopter deletes the release secrets of a former helm install so that
// helm no longer owns the objects (argocd.sh gitlab_release_adopter).
func (r *run) releaseAdopter() {
	_, _ = r.kubectlDevzone([]string{"-n", r.namespace(), "delete", "secret",
		"-l", "owner=helm,name=gitlab", "--ignore-not-found"})
}

// applicationApply applies the Application devzone-gitlab on the wrapper
// chart at the revision, the internal URL of the webservice following the
// namespace of the instance (argocd.sh gitlab_application_apply). When a
// GitOps repository is designated in .argocd.conf, the Application is written
// into it as apps/devzone-gitlab.yaml (gitops.sh gitops_apply_application);
// without a repository it is applied directly.
func (r *run) applicationApply() int {
	revision := r.argocdRevision()
	fmt.Fprintf(r.out(), "▶ Application devzone-gitlab (Argo CD, charts/devzone-gitlab at %s)…\n", revision)
	manifest := applicationManifest(r.namespace(), r.repoURL(), revision,
		"gitlab-runner.gitlabUrl=http://gitlab-webservice-default."+r.namespace()+".svc:8181")
	if repo := r.gitopsRepo(); repo != "" {
		if err := r.gitopsWriteApp("devzone-gitlab", manifest, "devzone: application devzone-gitlab"); err != nil {
			fmt.Fprintf(r.errOut(), "devzone : application devzone-gitlab not written to the GitOps repository (%s): %v\n", repo, err)
			return 1
		}
	} else if _, err := r.kubectlDevzoneWithStdin([]string{"-n", "devzone-argocd", "apply", "-f", "-"}, manifest); err != nil {
		return 1
	}
	_, _ = r.kubectlDevzone([]string{"-n", "devzone-argocd", "annotate", "application.argoproj.io",
		"devzone-gitlab", "argocd.argoproj.io/refresh=normal", "--overwrite"})
	return 0
}

// confValue returns the value of key in the section of .argocd.conf
// (conf_get of conf.sh: the first line key=value of the section, comments and
// blanks dropped, "" when absent).
func (r *run) confValue(section, key string) string {
	data, err := os.ReadFile(r.root + "/.argocd.conf")
	if err != nil {
		return ""
	}
	name := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			name = strings.TrimSpace(line[1 : len(line)-1])
			continue
		}
		if name != section {
			continue
		}
		i := strings.IndexByte(line, '=')
		if i < 0 || strings.TrimSpace(line[:i]) != key {
			continue
		}
		value := strings.TrimSpace(line[i+1:])
		if j := strings.IndexByte(value, '#'); j >= 0 {
			value = strings.TrimSpace(value[:j])
		}
		return value
	}
	return ""
}

// gitopsRepo returns the GitOps repository designated in .argocd.conf
// ([argocd] repo of gitops.sh gitops_repo), "" when none is designated.
func (r *run) gitopsRepo() string {
	repo := r.confValue("argocd", "repo")
	if repo == "" || repo == "none" {
		return ""
	}
	return repo
}

// gitopsProvider returns the provider of the GitOps repository ("gitlab" or
// empty like gitops_is_gitlab of gitops.sh).
func (r *run) gitopsProvider() string {
	return r.confValue("argocd", "provider")
}

// applicationExists reports whether the Application devzone-gitlab is in the
// devzone-argocd namespace (catalogue_argocd_application_exists).
func (r *run) applicationExists() bool {
	if r.stateValue("argocd") != "on" {
		return false
	}
	_, err := r.kubectlDevzone([]string{"-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-gitlab"})
	return err == nil
}

// applicationRetirer removes the Application when GitLab is uninstalled: its
// resources leave with it (argocd.sh gitlab_application_retirer).
func (r *run) applicationRetirer() {
	if !r.applicationExists() {
		return
	}
	_, _ = r.kubectlDevzone([]string{"-n", "devzone-argocd", "delete", "application.argoproj.io",
		"devzone-gitlab", "--ignore-not-found", "--wait=true"})
}

// applicationManifest returns the Application manifest of the gitlab service,
// generated like application.sh of the devzone repository: one Helm
// parameter per key=value of params.
func applicationManifest(namespace, repo, revision string, params ...string) string {
	var b strings.Builder
	b.WriteString(`apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devzone-gitlab
  namespace: devzone-argocd
  labels:
    app.kubernetes.io/managed-by: devzone
    devzone.io/kind: service
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ` + repo + `
    targetRevision: ` + revision + `
    path: charts/devzone-gitlab`)
	if len(params) > 0 {
		b.WriteString("\n    helm:\n      parameters:\n")
		for _, p := range params {
			name, value, _ := strings.Cut(p, "=")
			b.WriteString("        - name: " + name + "\n          value: \"" + value + "\"\n")
		}
	}
	b.WriteString(`
  destination:
    server: https://kubernetes.default.svc
    namespace: ` + namespace + `
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
`)
	return b.String()
}
