package workspace

import (
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// kubeEnv holds what a readiness check touches, injected so that no test calls
// a real kubectl or asks the PATH for a real program.
type kubeEnv struct {
	runner   Runner
	lookPath func(string) (string, error)
}

// KubeReady reports whether kubectl and helm are present and the cluster
// answers within five seconds, as the former kube_ready_reason did. It returns
// an empty reason and true when ready. With hint, the reason is the user message
// ("✖ …" plus the contexts tip) instead of the short one. The wording is
// product-neutral: the cluster is described as it is, wherever it runs.
func KubeReady(r Runner, hint bool) (string, bool) {
	return kubeEnv{runner: r, lookPath: exec.LookPath}.ready(hint)
}

// ready is the check itself. A missing program is reported before any call; a
// devzone context, when declared, is the one probed.
func (e kubeEnv) ready(hint bool) (string, bool) {
	if _, err := e.lookPath("kubectl"); err != nil {
		return say("kubectl missing", hint), false
	}
	if _, err := e.lookPath("helm"); err != nil {
		return say("helm missing", hint), false
	}
	flag := contextFlag(e.runner)
	args := append([]string{"cluster-info", "--request-timeout=5s"}, flag...)
	if status, err := e.runner.Kubectl(args, nil, io.Discard, io.Discard); err == nil && status == 0 {
		return "", true
	}
	context, server := e.describe(flag)
	if hint {
		return fmt.Sprintf("✖ Kubernetes cluster %s unreachable (%s)\n  Check the contexts: kubectl config get-contexts", context, server), false
	}
	return fmt.Sprintf("cluster %s unreachable (%s)", context, server), false
}

// describe returns the context being used and the server it points at. A
// missing value is spelled "none" and "unknown server", as in the shell.
func (e kubeEnv) describe(flag []string) (string, string) {
	context := "none"
	if len(flag) > 0 {
		context = flag[1]
	} else {
		var current strings.Builder
		_, _ = e.runner.Kubectl([]string{"config", "current-context"}, nil, &current, io.Discard)
		if value := strings.TrimSpace(current.String()); value != "" {
			context = value
		}
	}
	args := append([]string{"config", "view", "--minify"}, flag...)
	args = append(args, "-o", `jsonpath={.clusters[0].cluster.server}`)
	var out strings.Builder
	_, _ = e.runner.Kubectl(args, nil, &out, io.Discard)
	server := strings.TrimSpace(out.String())
	if server == "" {
		server = "unknown server"
	}
	return context, server
}

// say writes the short reason, or the user line when hint is set.
func say(reason string, hint bool) string {
	if hint {
		return "✖ " + reason
	}
	return reason
}
