package gitlab

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// chartDepend adds the gitlab repository to helm (idempotent) and builds the
// dependencies of the wrapper chart (chart.sh gitlab_chart_depend).
func (r *run) chartDepend() int {
	_, _ = r.runner().Run(r.ctx, "helm",
		[]string{"repo", "add", "gitlab", "https://charts.gitlab.io", "--force-update"}, exec.Opts{})
	res, err := r.runner().Run(r.ctx, "helm",
		[]string{"dependency", "build", r.root + "/charts/devzone-gitlab"}, exec.Opts{})
	if err != nil || res.Code != 0 {
		return 1
	}
	return 0
}

// attente is the timeout of the helm passes and of the waits of the module
// (GITLAB_ATTENTE, default 1200).
func (r *run) attente() string {
	if a := os.Getenv("GITLAB_ATTENTE"); a != "" {
		return a
	}
	return "1200"
}

// helmPass one helm pass of the wrapper chart; the webservice URL of the
// runner follows the namespace of the instance (chart.sh gitlab_helm_pass).
func (r *run) helmPass(replicas int) int {
	args := []string{
		"upgrade", "--install", "gitlab", r.root + "/charts/devzone-gitlab",
		"--namespace", r.namespace(),
		"--create-namespace",
		"--timeout", r.attente() + "s",
		"--wait",
		"--set", "gitlab-runner.gitlabUrl=http://gitlab-webservice-default." + r.namespace() + ".svc:8181",
		"--set", fmt.Sprintf("gitlab-runner.replicas=%d", replicas),
	}
	res, err := r.helmAdmin(args)
	if err != nil {
		return 1
	}
	return res.Code
}

// runnerAncienRetirer removes the release gitlab-runner of the installations
// before the wrapper chart (#396, chart.sh gitlab_runner_ancien_retirer).
func (r *run) runnerAncienRetirer() {
	_, _ = r.helmAdmin([]string{"uninstall", "gitlab-runner", "--namespace", r.namespace()})
}
