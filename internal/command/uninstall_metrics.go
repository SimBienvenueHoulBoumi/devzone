package command

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	fwexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// lookPath finds kubectl on the host. A variable, so that the tests answer
// without a real kubectl.
var lookPath = exec.LookPath

// localContextPattern selects the kubeconfig contexts of the host local clusters
// (kind, the desktop engine, Rancher Desktop, OrbStack, minikube).
var localContextPattern = regexp.MustCompile(`^(kind-.*|docker-desktop|rancher-desktop|orbstack|minikube)$`)

// metricsLabelValues are the values of the devzone label on a metrics-server
// installed by devzone ("installe" in the shell, "installed" in the Go command).
var metricsLabelValues = []string{"installe", "installed"}

// findMetricsServers sorts the reachable host local clusters: the ones whose
// metrics-server carries the devzone label are returned in metrics, the others
// in foreign. kubectlMissing is true when kubectl is not on the host. A cluster
// that does not answer, or has no metrics-server, is skipped.
func findMetricsServers(ctx context.Context, runner fwexec.Runner) (metrics, foreign []string, kubectlMissing bool) {
	if _, err := lookPath("kubectl"); err != nil {
		return nil, nil, true
	}
	res, err := runner.Run(ctx, "kubectl", []string{"config", "get-contexts", "-o", "name"}, fwexec.Opts{})
	if err != nil || res.Code != 0 {
		return nil, nil, false
	}
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		c := strings.TrimSpace(line)
		if !localContextPattern.MatchString(c) || !clusterAnswers(ctx, runner, c) {
			continue
		}
		mark, ok := metricsLabel(ctx, runner, c)
		if !ok {
			continue
		}
		if isDevzoneMark(mark) {
			metrics = append(metrics, c)
		} else {
			foreign = append(foreign, c)
		}
	}
	return metrics, foreign, false
}

// clusterAnswers reports whether the API server of a context answers /readyz.
func clusterAnswers(ctx context.Context, runner fwexec.Runner, kubeCtx string) bool {
	res, err := runner.Run(ctx, "kubectl", kubectlArgs(kubeCtx, "get", "--raw", "/readyz"), fwexec.Opts{})
	return err == nil && res.Code == 0
}

// metricsLabel returns the devzone label of the metrics-server deployment of a
// context; ok is false when there is no such deployment.
func metricsLabel(ctx context.Context, runner fwexec.Runner, kubeCtx string) (string, bool) {
	args := kubectlArgs(kubeCtx, "-n", "kube-system", "get", "deployment", "metrics-server", "-o", "jsonpath={.metadata.labels.devzone}")
	res, err := runner.Run(ctx, "kubectl", args, fwexec.Opts{})
	if err != nil || res.Code != 0 {
		return "", false
	}
	return strings.TrimSpace(string(res.Stdout)), true
}

// isDevzoneMark reports whether a label value is the one devzone sets.
func isDevzoneMark(mark string) bool {
	for _, v := range metricsLabelValues {
		if mark == v {
			return true
		}
	}
	return false
}

// kubectlArgs prefixes the arguments with the context and the request timeout,
// as every host cluster call of the shell uninstaller did.
func kubectlArgs(kubeCtx string, args ...string) []string {
	return append([]string{"--context", kubeCtx, "--request-timeout=5s"}, args...)
}

// metricsManifestURL returns the release manifest of the metrics-server pinned in
// .devcontainer/versions.env (METRICS_SERVER_VERSION), the one devzone installed.
func metricsManifestURL(root string) string {
	data, _ := os.ReadFile(filepath.Join(root, ".devcontainer", "versions.env"))
	version := ""
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, "METRICS_SERVER_VERSION="); ok {
			version = v
			break
		}
	}
	return "https://github.com/kubernetes-sigs/metrics-server/releases/download/" + version + "/components.yaml"
}

// removeMetricsServers deletes the metrics-server devzone installed, from each
// host cluster it was found on. It returns 1 when one deletion failed.
func removeMetricsServers(ctx context.Context, runner fwexec.Runner, h hostPlan, out, errOut io.Writer) int {
	status := 0
	for _, c := range h.metrics {
		res, err := runner.Run(ctx, "kubectl", kubectlArgs(c, "delete", "-f", h.manifest, "--ignore-not-found"), fwexec.Opts{})
		if err != nil || res.Code != 0 {
			fmt.Fprintf(errOut, "✖ metrics-server %s: %s\n", c, failureText(res, err))
			status = 1
			continue
		}
		fmt.Fprintf(out, "✔ metrics-server removed: %s\n", c)
	}
	return status
}
