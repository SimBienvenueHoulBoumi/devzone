package gitlab

import (
	"fmt"
	"os"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// uninstall removes GitLab: relays, Helm releases and the namespace of the
// instance only. The Rails secret is kept (browser sessions valid at the
// reinstallation), unless a complete uninstall is wanted (--yes): it then
// goes with the data (installation.sh gitlab_uninstall).
func (r *run) uninstall(args []string) int {
	deleteSecret := false
	for _, arg := range args {
		switch arg {
		case "--yes":
			deleteSecret = true
		default:
			fmt.Fprintf(r.errOut(), "devzone : gitlab uninstall : unknown argument : %s\n", arg)
			return 2
		}
	}
	fmt.Fprintln(r.out(), "▶ Uninstalling GitLab…")
	r.gitlabRelayStop()
	for _, dir := range []string{"gitlab-web", "gitlab-ssh", "gitlab-8929", "gitlab-2224"} {
		_ = os.RemoveAll(r.relayDir(dir))
	}
	r.applicationRetirer()
	_, _ = r.helmAdmin([]string{"uninstall", "gitlab", "--namespace", r.namespace()})
	r.runnerAncienRetirer()
	_, _ = r.kubectlAdmin([]string{"delete", "namespace", r.namespace(), "--ignore-not-found"})
	if deleteSecret {
		_ = os.RemoveAll(r.secretsDir())
		fmt.Fprintln(r.out(), "Rails secret deleted with the GitLab data.")
	} else if info, err := os.Stat(r.secretsDir()); err == nil && info.IsDir() {
		entries, _ := os.ReadDir(r.secretsDir())
		for _, entry := range entries {
			if entry.Name() == "rails-secret.yaml" {
				continue
			}
			_ = os.RemoveAll(r.secretsDir() + "/" + entry.Name())
		}
		if _, err := os.Stat(r.railsFile()); err == nil {
			fmt.Fprintln(r.out(), "Rails secret kept in workspace/.gitlab/rails-secret.yaml (browser sessions valid at reinstallation)")
		}
	}
	r.hostRemove()
	fmt.Fprintln(r.out(), "✔ GitLab uninstalled.")
	r.regeneratePasswords()
	return 0
}

// migrate installs and seeds in the services cluster, then deletes the old
// kind-gitlab cluster after confirmation (or --yes) (installation.sh
// gitlab_migrate).
func (r *run) migrate(args []string) int {
	yes := false
	for _, arg := range args {
		switch arg {
		case "--yes":
			yes = true
		default:
			fmt.Fprintf(r.errOut(), "devzone : gitlab migrate : unknown argument : %s (devzone gitlab migrate [--yes])\n", arg)
			return 2
		}
	}

	fmt.Fprintln(r.out(), "▶ Migrating GitLab from the old kind cluster…")
	fmt.Fprintln(r.out(), "  This is a test GitLab: the demo project and the runner are recreated, the rest is lost.")
	if code := r.install(); code != 0 {
		return code
	}

	if !contains(r.kindClusters(), r.oldCluster()) {
		fmt.Fprintf(r.out(), "✔ No old cluster %s to delete.\n", r.oldContext())
		return 0
	}
	if !yes {
		if !r.interactive() {
			fmt.Fprintf(r.errOut(), "devzone : gitlab : confirmation impossible without a terminal: devzone gitlab migrate --yes (old cluster %s kept)\n", r.oldContext())
			return 2
		}
		fmt.Fprintf(r.errOut(), "Delete the old cluster %s and its data? [y/N] ", r.oldContext())
		switch r.readAnswer() {
		case "y", "Y", "yes":
		default:
			fmt.Fprintf(r.out(), "Aborted: old cluster %s kept.\n", r.oldContext())
			return 0
		}
	}

	r.kindDeleteCluster(r.oldCluster())
	_, _ = r.kubectlDevzone([]string{"config", "delete-context", r.oldContext()})
	_, _ = r.kubectlDevzone([]string{"config", "delete-cluster", r.oldContext()})
	_, _ = r.kubectlDevzone([]string{"config", "delete-user", r.oldContext()})
	fmt.Fprintf(r.out(), "✔ Old cluster %s deleted.\n", r.oldContext())
	return 0
}

// oldCluster is the name of the old kind cluster (gitlab + suffix).
func (r *run) oldCluster() string {
	return "gitlab" + instanceSuffix()
}

// oldContext is the name of the old kubectl context (kind-gitlab + suffix).
func (r *run) oldContext() string {
	return "kind-gitlab" + instanceSuffix()
}

// kindClusters returns the names of the kind clusters (kind get clusters).
func (r *run) kindClusters() []string {
	res, err := r.runner().Run(r.ctx, "kind", []string{"get", "clusters"}, exec.Opts{})
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

// kindDeleteCluster deletes a kind cluster (kind delete cluster --name).
func (r *run) kindDeleteCluster(name string) {
	_, _ = r.runner().Run(r.ctx, "kind", []string{"delete", "cluster", "--name", name}, exec.Opts{})
}

// contains reports whether the list holds value.
func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// interactive reports whether the input is a terminal (cluster_interactive of
// cluster.sh); DEVZONE_INTERACTIVE=1 is used by the tests.
func (r *run) interactive() bool {
	return os.Getenv("DEVZONE_INTERACTIVE") == "1" || isTerminal()
}

// isTerminal reports whether stdin is a terminal, like [ -t 0 ] of
// cluster_interactive: a character device that is not the null device.
func isTerminal() bool {
	info, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	if null, err := os.Stat(os.DevNull); err == nil && os.SameFile(info, null) {
		return false
	}
	return true
}

// readAnswer reads one line of stdin like the shell `read -r answer`
// (empty on EOF).
func (r *run) readAnswer() string {
	var line []byte
	buf := make([]byte, 1)
	for {
		n, err := os.Stdin.Read(buf)
		if n > 0 {
			if buf[0] == '\n' {
				break
			}
			line = append(line, buf[0])
		}
		if err != nil {
			break
		}
	}
	return string(line)
}
