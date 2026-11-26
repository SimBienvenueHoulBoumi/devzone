package gitlab

import (
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// secretsDir returns the folder of the secrets of the module (600 files).
func (r *run) secretsDir() string {
	return r.root + "/workspace/.gitlab"
}

// railsFile returns the path of the kept Rails secret manifest.
func (r *run) railsFile() string {
	return r.secretsDir() + "/rails-secret.yaml"
}

// rootTokenFile returns the path of the root token of the seed.
func (r *run) rootTokenFile() string {
	return r.secretsDir() + "/root-token"
}

// helmAdmin runs helm with the administrator context of the instance, like
// account_helm of kube-account.sh.
func (r *run) helmAdmin(args []string) (exec.Result, error) {
	conf := r.adminKubeconfig(r.accountContext())
	all := append([]string{"--kubeconfig", conf, "--kube-context", r.accountContext()}, args...)
	return r.runner().Run(r.ctx, "helm", all, exec.Opts{})
}

// kubectlAdmin runs kubectl with the administrator context, like account_admin.
func (r *run) kubectlAdmin(args []string) (exec.Result, error) {
	ctx := r.accountContext()
	conf := r.adminKubeconfig(ctx)
	all := append([]string{"--kubeconfig=" + conf, "--context", ctx}, args...)
	return r.runner().Run(r.ctx, "kubectl", all, exec.Opts{})
}

// kubectlDevzone runs kubectl on the devzone context, as the seed and the
// relay do (`kubectl --context devzone ...`).
func (r *run) kubectlDevzone(args []string) (exec.Result, error) {
	all := append([]string{"--context", "devzone"}, args...)
	return r.runner().Run(r.ctx, "kubectl", all, exec.Opts{})
}

// install installs GitLab and its runner in the services cluster, then
// prepares the access (web/SSH relay, /etc/hosts) and the seed of the test
// data (installation.sh gitlab_install).
func (r *run) install() int {
	fmt.Fprintln(r.out(), "▶ Checking the allocatable memory of the services cluster…")
	if code := r.checkModuleMemory("gitlab", 8, ""); code != 0 {
		return code
	}
	parArgocd := r.argocdActive()
	revision := ""
	if parArgocd {
		var err error
		revision, err = r.argocdRevision()
		if err != nil {
			fmt.Fprintln(r.errOut(), err)
			fmt.Fprintln(r.errOut(), "nothing was installed: set DEVZONE_ARGOCD_REVISION=<tag or branch> (devzone argocd init), then: devzone enable gitlab")
			return 1
		}
	}
	if err := os.MkdirAll(r.secretsDir(), 0o755); err != nil {
		fmt.Fprintf(r.errOut(), "devzone : gitlab : %v\n", err)
		return 1
	}
	r.namespacePrepare()

	r.secretsApply()
	r.runnerAncienRetirer()

	if parArgocd {
		if code := r.applicationApply(revision); code != 0 {
			return code
		}
	} else {
		fmt.Fprintf(r.out(), "▶ Installing the GitLab chart in %s…\n", r.namespace())
		if code := r.chartDepend(); code != 0 {
			return code
		}
		if code := r.helmPass(0); code != 0 {
			return code
		}
	}

	if code := r.gitlabRelayStart(); code != 0 {
		return code
	}
	r.hostSet()

	if code := r.waitReady(); code != 0 {
		return code
	}
	if code := r.seed(); code != 0 {
		return code
	}
	if _, err := os.Stat(r.railsFile()); err != nil {
		r.secretsCopy()
	}
	if !parArgocd {
		fmt.Fprintln(r.out(), "▶ GitLab Runner executor…")
		if code := r.helmPass(1); code != 0 {
			return code
		}
	}

	r.secretsWarn()

	fmt.Fprintln(r.out(), "▶ Installation complete.")
	fmt.Fprintln(r.out(), "  URL: http://gitlab.localhost:8929")
	fmt.Fprintln(r.out(), "  User: root")
	fmt.Fprintf(r.out(), "  Root password: %s/root-password (chmod 600)\n", r.secretsDir())
	r.pipelineLaunch()
	return 0
}
