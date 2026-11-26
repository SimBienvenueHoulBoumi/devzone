package argocd

import (
	"fmt"
	"strings"
)

const (
	// metricsRepo is the official Helm repository of metrics-server.
	metricsRepo = "https://kubernetes-sigs.github.io/metrics-server"
	// metricsChart is the chart published in that repository.
	metricsChart = "metrics-server"
	// metricsNS is the namespace of the Metrics API deployment.
	metricsNS = "kube-system"
)

// dependencyCmd handles "dependency metrics-server on|off". Dependencies are
// created as Applications from their official source at a pinned version;
// removing one deletes only the Application and the objects it created.
func (m *module) dependencyCmd(args []string) int {
	if len(args) != 2 || args[0] != "metrics-server" {
		fmt.Fprintln(m.errOut, "usage: devzone argocd dependency metrics-server on|off")
		return 2
	}
	switch args[1] {
	case "on":
		return m.metricsServerApply()
	case "off":
		return m.gitopsDeleteApplication("devzone-metrics-server", "cascade")
	default:
		fmt.Fprintln(m.errOut, "usage: devzone argocd dependency metrics-server on|off")
		return 2
	}
}

// metricsServerApply applies metrics-server from its official chart with the
// kubelet flag the local clusters need, without changing a devzone chart. The
// chart version comes from versions.env: no dependency follows a moving branch.
func (m *module) metricsServerApply() int {
	chart, app, err := m.metricsPins()
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	manifest, err := m.renderChartApp("devzone-metrics-server", metricsNS, metricsRepo,
		metricsChart, chart, []string{"args[0]=--kubelet-insecure-tls"})
	if err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	res, err := m.runner.Run(m.ctx, "kubectl",
		[]string{"--context", "devzone", "apply", "-f", "-"}, stdinOpt(manifest))
	if err != nil || res.Code != 0 {
		if err != nil {
			fmt.Fprintln(m.errOut, err)
		} else {
			m.errOut.Write(res.Stderr)
		}
		return 1
	}
	fmt.Fprintf(m.out, "✔ Application devzone-metrics-server: %s chart %s (app %s) → %s\n", metricsRepo, chart, app, metricsNS)
	return 0
}

// renderChartApp renders an Application manifest sourced from an external
// Helm chart, through the shared renderer.
func (m *module) renderChartApp(name, namespace, repo, chart, version string, params []string) (string, error) {
	var b strings.Builder
	if err := RenderChartApplication(&b, name, namespace, repo, chart, version, params); err != nil {
		return "", err
	}
	return b.String(), nil
}
