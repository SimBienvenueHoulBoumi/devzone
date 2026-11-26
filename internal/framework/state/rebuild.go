package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const clusterLabel = "app.kubernetes.io/managed-by=devzone"

// rebuildLocked rebuilds the state from devzone-labelled namespaces in the services cluster.
func (s *State) rebuildLocked(modules []string, run Runner, warn func(string)) (bool, error) {
	if run == nil {
		return false, nil
	}
	namespaces, err := labelledNamespaces(run)
	if err != nil || len(namespaces) == 0 {
		return false, nil
	}
	seen := false
	var b strings.Builder
	for _, m := range modules {
		v := "off"
		if namespaces["devzone-"+m] {
			v = "on"
			seen = true
		}
		fmt.Fprintf(&b, "%s=%s\n", m, v)
	}
	clusterHost := ""
	clusterCtx, err := runOut(run, "kubectl", "config", "view", "-o", "jsonpath={.contexts[?(@.name==\"devzone\")].context.cluster}")
	if err == nil && clusterCtx != "" {
		clusterHost = hostContextOfCluster(run, clusterCtx)
		if clusterHost != "" {
			fmt.Fprintf(&b, "cluster=%s\n", clusterHost)
		}
	}
	if !seen {
		return false, nil
	}
	if err := s.replaceBytesLocked([]byte(b.String())); err != nil {
		return false, nil
	}
	warn(fmt.Sprintf("devzone : state rebuilt from the namespaces of the services cluster: %s (confirm with devzone apply)", s.path))
	if clusterHost == "" {
		warn(fmt.Sprintf("devzone : no host context points to the services cluster: no cluster= line in %s", s.path))
	}
	_ = s.RecoveryMark()
	return true, nil
}

// labelledNamespaces returns the set of devzone-managed namespaces.
func labelledNamespaces(run Runner) (map[string]bool, error) {
	out, err := runOut(run, "kubectl", "get", "namespaces", "-l", clusterLabel, "-o", "name")
	if err != nil {
		return nil, err
	}
	set := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		line = strings.TrimPrefix(line, "namespace/")
		if line != "" {
			set[line] = true
		}
	}
	return set, nil
}

// hostContextOfCluster finds the host kubeconfig context pointing at cluster.
func hostContextOfCluster(run Runner, cluster string) string {
	host := os.Getenv("DEVZONE_KUBE_HOST")
	if host == "" {
		host = filepath.Join(os.Getenv("HOME"), ".kube", "hote.config")
	}
	out, err := runOutEnv(run, []string{"KUBECONFIG=" + host}, "kubectl", "config", "get-contexts", "-o", "name")
	if err != nil {
		return ""
	}
	for _, ctx := range strings.Split(out, "\n") {
		ctx = strings.TrimSpace(ctx)
		if ctx == "" || ctx == "devzone" {
			continue
		}
		got, err := runOutEnv(run, []string{"KUBECONFIG=" + host}, "kubectl", "config", "view", "-o", fmt.Sprintf("jsonpath={.contexts[?(@.name==\"%s\")].context.cluster}", ctx))
		if err == nil && got == cluster {
			return ctx
		}
	}
	return ""
}

// runOut executes a command and returns trimmed stdout on success.
func runOut(run Runner, name string, args ...string) (string, error) {
	stdout, _, err := run(name, args...)
	return strings.TrimSpace(stdout), err
}

// runOutEnv prepends env assignments through env command for simple Runner impls.
func runOutEnv(run Runner, env []string, name string, args ...string) (string, error) {
	cmdArgs := append([]string{}, env...)
	cmdArgs = append(cmdArgs, name)
	cmdArgs = append(cmdArgs, args...)
	stdout, _, err := run("env", cmdArgs...)
	return strings.TrimSpace(stdout), err
}
