package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// printStatusDetails writes the GitOps, catalog, cluster, relay and credentials
// lines of the summary, in the same order as the removed shell function.
func printStatusDetails(ctx *cli.Context, d jsonDeps) {
	script := podCommand(d)
	inPod := os.Getenv("DEVZONE_WORKSPACE") == "kubernetes"
	printGitopsLine(ctx, d, script, inPod)
	printCatalogLine(ctx, d, script)
	printGitlabSecretLine(ctx, d)
	printClusterLines(ctx, d, script)
	printRBACLine(ctx, d)
	printPortsLine(ctx, d)
	printCredentialsLine(ctx, d)
	printPackagesLine(ctx)
}

// printGitopsLine reports the configured GitOps repository, or the pod line
// when no repository is declared in the instance configuration.
func printGitopsLine(ctx *cli.Context, d jsonDeps, script string, inPod bool) {
	repo := argocdRepo(d.root)
	if value, ok := repo.(string); ok && value != "" && value != "none" {
		fmt.Fprintf(ctx.Out, "  ○ argocd          GitOps repository: %s\n", value)
		return
	}
	if inPod {
		out, _, _ := d.runEnv([]string{"DEVZONE_STATE=" + d.st.Path()}, script, "state", "gitops-line")
		_, _ = fmt.Fprint(ctx.Out, out)
		return
	}
	fmt.Fprintln(ctx.Out, "  ○ argocd          no GitOps repository: devzone argocd init")
}

// printCatalogLine prints the catalog summary when the catalog folder exists.
func printCatalogLine(ctx *cli.Context, d jsonDeps, script string) {
	if _, err := os.Stat(filepath.Join(d.code, "catalog")); err != nil {
		return
	}
	out, _, _ := d.run(script, "catalog", "resume")
	_, _ = fmt.Fprint(ctx.Out, out)
}

// printGitlabSecretLine warns that a reinstalled GitLab lost its Rails secret.
func printGitlabSecretLine(ctx *cli.Context, d jsonDeps) {
	if d.st.Get("gitlab") != "on" {
		return
	}
	secret := filepath.Join(d.root, "workspace", ".gitlab", "rails-secret.yaml")
	if _, err := os.Stat(secret); err != nil {
		fmt.Fprintln(ctx.Out, "  ⚠ gitlab          GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost")
	}
}

// printClusterLines reports a remote services cluster, a stale old cluster, an
// internal working cluster and refuses to change the working context.
func printClusterLines(ctx *cli.Context, d jsonDeps, script string) {
	cluster, _, _ := d.run(script, "kube", "saved")
	cluster = trimNewlines(cluster)
	if cluster != "" {
		_, code, err := d.run(script, "kube", "local", cluster)
		if err != nil || code != 0 {
			fmt.Fprintf(ctx.Out, "  ⚠ cluster        remote: %s — services on a remote cluster\n", cluster)
		}
	}
	_, _, _ = d.run(script, "cluster", "clean", "--quiet")
	clusters, _, _ := d.run("kind", "get", "clusters")
	old := "gitlab" + instanceSuffix()
	for _, line := range strings.Split(clusters, "\n") {
		if strings.TrimSpace(line) == old {
			fmt.Fprintf(ctx.Out, "  ⚠ old kind-gitlab cluster%s: devzone gitlab migrate\n", instanceSuffix())
		}
	}
	work, _, _ := d.run("kubectl", "config", "current-context")
	work = trimNewlines(work)
	if !strings.HasPrefix(work, "kind-gitlab") && !strings.HasPrefix(work, "kind-devzone") {
		return
	}
	hostConfig := os.Getenv("DEVZONE_KUBE_HOST")
	if hostConfig == "" {
		hostConfig = filepath.Join(os.Getenv("HOME"), ".kube", "hote.config")
	}
	out, _, _ := d.runEnv([]string{"KUBECONFIG=" + hostConfig}, "kubectl", "config", "current-context")
	hostCtx := trimNewlines(out)
	if hostCtx == "" {
		return
	}
	if _, code, err := d.run(script, "kube", "reachable", hostCtx); err == nil && code == 0 {
		fmt.Fprintf(ctx.Out, "  ⚠ working cluster: %s (devzone internal cluster); go back: devzone use %s\n", work, hostCtx)
	}
}

// instanceSuffix returns the suffix of the instance-specific old cluster, empty
// for the default devzone instance.
func instanceSuffix() string {
	name := os.Getenv("DEVZONE_INSTANCE")
	if name == "" || name == "devzone" {
		return ""
	}
	return "-" + name
}

// printRBACLine warns when the pod service account can read PostgreSQL secrets.
func printRBACLine(ctx *cli.Context, d jsonDeps) {
	out, _, _ := d.run("kubectl", "auth", "can-i", "--as=system:serviceaccount:default:default", "get", "secrets", "-n", config.NamespacePostgres)
	if trimNewlines(out) == "yes" {
		fmt.Fprintln(ctx.Out, "  ⚠ rbac          : access to "+config.NamespacePostgres+" secrets not restricted")
	}
}

// printPortsLine reports the relays to the workstation, or their absence when
// the port command cannot be consulted.
func printPortsLine(ctx *cli.Context, d jsonDeps) {
	out, code, err := d.runEnv([]string{"DEVZONE_STATE=" + d.st.Path()}, "devzone", "port", "resume")
	if err != nil || code != 0 {
		out = "none"
	}
	value := trimNewlines(out)
	if value == "" {
		value = "none"
	}
	if strings.HasPrefix(value, "none") {
		fmt.Fprintf(ctx.Out, "  ○ ports to the workstation %s\n", value)
		return
	}
	fmt.Fprintf(ctx.Out, "  ✔ ports to the workstation %s\n", value)
}

// printCredentialsLine prints the path of the grouped credentials, never their
// content.
func printCredentialsLine(ctx *cli.Context, d jsonDeps) {
	path := filepath.Join(d.root, ".password")
	if _, err := os.Stat(path); err == nil {
		fmt.Fprintf(ctx.Out, "  ○ credentials: %s\n", path)
	}
}

// packageMarker returns the file that lists packages missing after a failed
// reapplication, from the environment or the temporary folder of this system.
func packageMarker() string {
	if path := os.Getenv("DEVZONE_PACKAGES_MARKER"); path != "" {
		return path
	}
	return filepath.Join(os.TempDir(), "devzone-packages.failed")
}

// printPackagesLine reports the packages of a failed reapplication, when the
// marker written by the packages command is present.
func printPackagesLine(ctx *cli.Context) {
	data, err := os.ReadFile(packageMarker())
	if err != nil {
		return
	}
	var names []string
	for _, line := range strings.Split(string(data), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	if len(names) > 0 {
		fmt.Fprintf(ctx.Out, "  ⚠ packages         %s: devzone packages\n", strings.Join(names, ", "))
	}
}
