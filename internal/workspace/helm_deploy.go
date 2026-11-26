package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// packageRoot returns the folder holding charts/ and package.json, searched
// from the binary like the bash entry point does for its chart_path.
func packageRoot() string {
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			dir = filepath.Dir(resolved)
		}
		if _, err := os.Stat(filepath.Join(dir, "charts")); err == nil {
			return dir
		}
		if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "charts")); err == nil {
			return filepath.Dir(dir)
		}
	}
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return "."
}

// helmFlag returns the context argument of helm, as helm_flag in
// manage/workspace.sh: --kube-context devzone when the kubeconfig declares it.
func helmFlag(r Runner) []string {
	if !declaresDevzone(r) {
		return nil
	}
	return []string{"--kube-context", kubeContext}
}

// DefaultImageTag reads the version of package.json, as default_image_tag in
// manage/workspace.sh: a development clone (0.0.0, absent version) uses latest.
func DefaultImageTag(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "package.json"))
	if err != nil {
		return "latest"
	}
	version := argocdVersionPattern.FindStringSubmatch(string(data))
	if len(version) != 2 || version[1] == "" || version[1] == "0.0.0" {
		return "latest"
	}
	return version[1]
}

// HelmDeploy installs or upgrades the workspace chart directly with helm, as
// workspace_helm_deploy in manage/workspace.sh. The egress parameters of the
// modules file are replayed at every call, with commas escaped for helm.
func HelmDeploy(r Runner, modules, repository, tag string, withImage bool, out, errOut io.Writer) int {
	args := append(helmFlag(r), "upgrade", "--install", "devzone-workspace",
		filepath.Join(packageRoot(), "charts", "devzone-workspace"),
		"--namespace", namespace, "--create-namespace")
	if withImage {
		args = append(args, "--set", "image.repository="+repository)
	}
	args = append(args, "--set", "image.tag="+tag)
	if tag == "latest" {
		args = append(args, "--set", "image.pullPolicy=Always")
	}
	params := strings.ReplaceAll(EgressParams(modules), ",", `\,`)
	for _, param := range strings.Fields(params) {
		args = append(args, "--set", param)
	}
	status, err := r.Helm(args, nil, out, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "devzone: cannot start helm: %v\n", err)
		return notStarted
	}
	return status
}
