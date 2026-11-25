// Package helm installs the devzone charts the same way as chart-direct.sh:
// render the chart, adopt existing objects, then let Helm own the release.
package helm

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Install renders charts/devzone-<svc>, adopts its existing objects in ns, then
// runs helm upgrade --install on the devzone context. It returns the rendered
// manifest and a status code for failures (2 for a missing chart, 1 otherwise).
func Install(ctx context.Context, runner exec.Runner, codeRoot, svc, ns string, sets []string, errOut io.Writer) (string, int) {
	if ctx == nil {
		ctx = context.Background()
	}
	// codeRoot is the .devcontainer folder: the charts are beside it, at the
	// root of the code tree (CHART_CODE of chart-direct.sh)
	chart := filepath.Join(filepath.Dir(codeRoot), "charts", "devzone-"+svc)
	if _, err := os.Stat(filepath.Join(chart, "Chart.yaml")); err != nil {
		fmt.Fprintf(errOut, "✖ %s : chart charts/devzone-%s missing (manage/docs/reference.md#devzone-charts)\n", svc, svc)
		return "", 2
	}
	args := []string{"template", svc, chart, "-n", ns}
	for _, set := range sets {
		args = append(args, "--set", set)
	}
	rendered, err := runner.Run(ctx, "helm", args, exec.Opts{})
	if err != nil || rendered.Code != 0 {
		if errOut != nil {
			_, _ = io.WriteString(errOut, string(rendered.Stderr))
		}
		return "", 1
	}
	adopt(ctx, runner, ns, svc, rendered.Stdout)
	args = []string{"--kube-context", "devzone", "upgrade", "--install", svc, chart, "-n", ns}
	for _, set := range sets {
		args = append(args, "--set", set)
	}
	res, err := runner.Run(ctx, "helm", args, exec.Opts{})
	if err != nil || res.Code != 0 {
		if errOut != nil {
			_, _ = io.WriteString(errOut, string(res.Stderr))
		}
		return string(rendered.Stdout), 1
	}
	return string(rendered.Stdout), 0
}

// adopt writes the Helm ownership annotations and label on the objects that
// already exist in ns, so that the release takes them over without recreating
// them. The rendered manifest is passed on stdin to the kubectl get call.
func adopt(ctx context.Context, runner exec.Runner, ns, svc string, manifest []byte) {
	found, err := runner.Run(ctx, "kubectl",
		[]string{"--context", "devzone", "-n", ns, "get", "-f", "-", "-o", "name", "--ignore-not-found"},
		exec.Opts{Stdin: strings.NewReader(string(manifest))})
	if err != nil || found.Code != 0 {
		return
	}
	for _, object := range strings.Fields(string(found.Stdout)) {
		_, _ = runner.Run(ctx, "kubectl", []string{
			"--context", "devzone", "-n", ns, "annotate", object,
			"meta.helm.sh/release-name=" + svc, "meta.helm.sh/release-namespace=" + ns, "--overwrite"}, exec.Opts{})
		_, _ = runner.Run(ctx, "kubectl", []string{
			"--context", "devzone", "-n", ns, "label", object,
			"app.kubernetes.io/managed-by=Helm", "--overwrite"}, exec.Opts{})
	}
}
