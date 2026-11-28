package gitlab

import (
	"fmt"
	"os"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
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

// argocdRevision returns the revision of the devzone charts through the shared
// rule: explicit setting, package version, or newest published tag containing
// the chart. It fails instead of returning an empty revision.
func (r *run) argocdRevision() (string, error) {
	return argocd.ResolveRevision(r.ctx, argocd.RevisionInputs{
		Runner:   r.runner(),
		Root:     r.root,
		ConfPath: r.root + "/.argocd.conf",
		Repo:     r.repoURL(),
		Chart:    "devzone-gitlab",
	})
}

// argocdActive reports whether the Application devzone-gitlab must be used:
// the module argocd is on, the chart is present and Argo CD is installed. The
// revision is resolved separately and its failure stops the installation.
func (r *run) argocdActive() bool {
	if r.stateValue("argocd") != "on" {
		return false
	}
	if _, err := os.Stat(r.root + "/charts/devzone-gitlab"); err != nil {
		return false
	}
	res, err := r.kubectlAdmin([]string{"get", "namespace", "devzone-argocd"})
	return err == nil && res.Code == 0
}

// applicationApply applies the Application devzone-gitlab on the wrapper
// chart at the revision, the internal URL of the webservice following the
// namespace of the instance. Existing helm objects are adopted as they are:
// no volume, no secret and no namespace is deleted. When a GitOps repository
// is designated in .argocd.conf, the Application is written into it as
// apps/devzone-gitlab.yaml; without a repository it is applied directly.
func (r *run) applicationApply(revision string) int {
	fmt.Fprintf(r.out(), "▶ Application devzone-gitlab (Argo CD, charts/devzone-gitlab at %s)…\n", revision)
	manifest := applicationManifestWithRelease(r.namespace(), r.repoURL(), revision, r.applicationReleaseName(),
		!r.applicationPresent(),
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

// applicationPresent reports whether the Application devzone-gitlab exists in
// the cluster. An existing one keeps its manual synchronization.
func (r *run) applicationPresent() bool {
	res, err := r.kubectlDevzone([]string{"-n", "devzone-argocd", "get", "application.argoproj.io", "devzone-gitlab"})
	return err == nil && res.Code == 0
}

// applicationReleaseName reads the Helm release name of an existing
// Application so an adopted GitLab keeps its object names and its data. An
// absent or empty release name falls back to "gitlab".
func (r *run) applicationReleaseName() string {
	res, err := r.kubectlDevzone([]string{"-n", "devzone-argocd", "get", "application.argoproj.io",
		"devzone-gitlab", "-o", "jsonpath={.spec.source.helm.releaseName}"})
	if err != nil || res.Code != 0 {
		return "gitlab"
	}
	name := strings.TrimSpace(string(res.Stdout))
	if name == "" {
		return "gitlab"
	}
	return name
}

// applicationManifest returns the safe Application manifest with the default
// Helm release name "gitlab".
func applicationManifest(namespace, repo, revision string, params ...string) string {
	return applicationManifestWithRelease(namespace, repo, revision, "gitlab", false, params...)
}

// applicationManifestWithRelease returns the Application manifest of the
// gitlab service: releaseName is a field of spec.source.helm, no cascade
// finalizer removes data and synchronization stays manual with PruneLast.
func applicationManifestWithRelease(namespace, repo, revision, releaseName string, first bool, params ...string) string {
	var b strings.Builder
	b.WriteString(`apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devzone-gitlab
  namespace: devzone-argocd
  labels:
    app.kubernetes.io/managed-by: devzone
    devzone.io/kind: service
spec:
  project: default
  source:
    repoURL: ` + repo + `
    targetRevision: ` + revision + `
    path: charts/devzone-gitlab
    helm:
      releaseName: ` + releaseName)
	if len(params) > 0 {
		b.WriteString(`
      parameters:`)
		for _, p := range params {
			name, value, _ := strings.Cut(p, "=")
			b.WriteString(`
        - name: ` + name + `
          value: "` + value + `"`)
		}
	}
	b.WriteString(`
  destination:
    server: https://kubernetes.default.svc
    namespace: ` + namespace + `
  syncPolicy:
`)
	if first {
		// A first install must deploy by itself; it never prunes nor self-heals,
		// so no object of an existing GitLab can be removed by Argo CD.
		b.WriteString(`    automated:
      prune: false
      selfHeal: false
`)
	}
	b.WriteString(`    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
`)
	return b.String()
}
