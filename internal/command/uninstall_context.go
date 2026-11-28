package command

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// errNoServicesCluster means no cluster of the devzone services is identified.
// The Kubernetes part is then skipped: the host resources are still removed.
var errNoServicesCluster = errors.New("no devzone services cluster identified")

// servicesContext returns the kubeconfig context of the devzone services: the
// cluster= line of the state file, else the shared context name when declared.
func servicesContext(ctx context.Context, runner exec.Runner, root string) (string, error) {
	if c, ok := state.New(root).GetOK("cluster"); ok {
		if c = strings.TrimSpace(c); c != "" {
			return c, nil
		}
	}
	if declaresDevzoneContext(ctx, runner) {
		return exec.ContextName(), nil
	}
	return "", fmt.Errorf("%w: no cluster= line in the state, no %q context in the kubeconfig",
		errNoServicesCluster, exec.ContextName())
}

// declaresDevzoneContext reports whether the kubeconfig lists the context that
// ContextName names, so the uninstall knows which one to remove from.
func declaresDevzoneContext(ctx context.Context, runner exec.Runner) bool {
	res, err := runner.Run(ctx, "kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Opts{})
	if err != nil || res.Code != 0 {
		return false
	}
	wanted := exec.ContextName()
	for _, name := range strings.Split(string(res.Stdout), "\n") {
		if strings.TrimSpace(name) == wanted {
			return true
		}
	}
	return false
}
