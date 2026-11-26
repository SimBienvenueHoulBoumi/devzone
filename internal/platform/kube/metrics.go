package kube

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// MetricsVersion is the pinned release of metrics-server installed by devzone.
const MetricsVersion = "v0.9.0"

// metricsVersion returns the pinned release. The version comes from versions.env
// of the installed code when that file is present, so the workstation installer
// and the pod read the same pin.
func metricsVersion() string {
	version := MetricsVersion
	script := os.Getenv("DEVZONE_POD_SCRIPT")
	if script == "" {
		script = "/usr/local/share/devzone/.devcontainer/devzone"
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(script), "versions.env"))
	if err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if value, ok := strings.CutPrefix(line, "METRICS_SERVER_VERSION="); ok && value != "" {
				version = strings.TrimSpace(value)
			}
		}
	}
	return version
}

// metricsManifest builds the manifest URL of the release in use.
func metricsManifest() string {
	return "https://github.com/kubernetes-sigs/metrics-server/releases/download/" + metricsVersion() + "/components.yaml"
}

// Metrics installs or removes metrics-server, as metrics-server.sh did. The
// "retirer" argument is the public subcommand name kept as is; the other
// arguments are explicit contexts, otherwise only local clusters are used.
func (k Kube) Metrics(ctx context.Context, args []string, out, errOut io.Writer) int {
	if ctx == nil {
		ctx = context.Background()
	}
	remove := len(args) > 0 && args[0] == "retirer"
	if remove {
		args = args[1:]
	}
	known, err := k.ConfigContexts(ctx)
	if err != nil {
		fmt.Fprintln(errOutOrDiscard(errOut), "metrics-server : unable to list the contexts")
		return 1
	}
	requested := len(args) > 0
	contexts := args
	if !requested {
		for _, name := range known {
			if k.IsLocal(name) {
				contexts = append(contexts, name)
			}
		}
	}
	code := 0
	for _, name := range contexts {
		if requested && !hasLine(strings.Join(known, "\n"), name) {
			fmt.Fprintf(errOutOrDiscard(errOut), "metrics-server : unknown context: %s (see kubectl config get-contexts)\n", name)
			code = 1
			continue
		}
		if remove {
			code = k.metricsRemove(ctx, name, out, errOut, code)
			continue
		}
		code = k.metricsInstall(ctx, name, requested, out, errOut, code)
	}
	if !requested && !remove {
		reachable := 0
		for _, name := range contexts {
			if k.ReachableTimeout(ctx, name, "5s") {
				reachable++
			}
		}
		if reachable == 0 {
			fmt.Fprintln(errOutOrDiscard(out), "metrics-server : no reachable local cluster; after kind create cluster: devzone metrics")
		}
	}
	return code
}

// metricsRemove removes metrics-server only where devzone installed it, leaving
// an installation made by someone else untouched.
func (k Kube) metricsRemove(ctx context.Context, name string, out, errOut io.Writer, code int) int {
	markRes, err := k.raw(ctx, "--context", name, "-n", "kube-system", "get", "deployment",
		"metrics-server", "-o", "jsonpath={.metadata.labels.devzone}")
	marked := err == nil && markRes.Code == 0 && strings.TrimSpace(string(markRes.Stdout)) == "installe"
	if marked {
		res, err := k.raw(ctx, "--context", name, "delete", "-f", metricsManifest(), "--ignore-not-found")
		if err == nil && res.Code == 0 {
			fmt.Fprintf(errOutOrDiscard(out), "metrics-server removed (%s) : %s\n", metricsVersion(), name)
		} else {
			fmt.Fprintf(errOutOrDiscard(errOut), "metrics-server : removal failed: %s\n", name)
			code = 1
		}
		return code
	}
	res, err := k.raw(ctx, "--context", name, "-n", "kube-system", "get", "deployment", "metrics-server")
	if err == nil && res.Code == 0 {
		fmt.Fprintf(errOutOrDiscard(errOut), "metrics-server present without a devzone mark, left: %s\n", name)
	}
	return code
}

// metricsInstall installs metrics-server on one reachable cluster and returns
// the accumulated exit status.
func (k Kube) metricsInstall(ctx context.Context, name string, requested bool, out, errOut io.Writer, code int) int {
	if !k.ReachableTimeout(ctx, name, "5s") {
		if requested {
			fmt.Fprintf(errOutOrDiscard(errOut), "metrics-server : cluster unreachable: %s\n", name)
			code = 1
		}
		return code
	}
	base := []string{"--context", name, "--request-timeout=5s"}
	present, err := k.raw(ctx, append(append([]string{}, base...), "get", "apiservice", "v1beta1.metrics.k8s.io")...)
	if err == nil && present.Code == 0 {
		fmt.Fprintf(errOutOrDiscard(out), "metrics-server : already present: %s\n", name)
		return code
	}
	applied, err := k.raw(ctx, append(append([]string{}, base...), "apply", "-f", metricsManifest())...)
	if err != nil || applied.Code != 0 {
		fmt.Fprintf(errOutOrDiscard(errOut), "metrics-server : installation failed: %s\n", name)
		code = 1
		return code
	}
	patch := `[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]`
	patched, err := k.raw(ctx, append(append([]string{}, base...),
		"-n", "kube-system", "patch", "deployment", "metrics-server", "--type=json", "-p", patch)...)
	labels, labelErr := k.raw(ctx, append(append([]string{}, base...),
		"-n", "kube-system", "label", "deployment", "metrics-server", "devzone=installe",
		"app.kubernetes.io/managed-by=devzone", "--overwrite")...)
	if err != nil || patched.Code != 0 || labelErr != nil || labels.Code != 0 {
		fmt.Fprintf(errOutOrDiscard(errOut), "metrics-server : installation failed: %s\n", name)
		code = 1
		return code
	}
	fmt.Fprintf(errOutOrDiscard(out), "metrics-server : installed (%s): %s (metrics within ~1 min)\n", metricsVersion(), name)
	return code
}
