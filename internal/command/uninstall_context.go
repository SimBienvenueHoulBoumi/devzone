package command

import (
	"context"
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

func servicesContext(ctx context.Context, runner exec.Runner, root string) (string, error) {
	if c, ok := state.New(root).GetOK("cluster"); ok {
		if c = strings.TrimSpace(c); c != "" {
			return c, nil
		}
	}
	if declaresDevzoneContext(ctx, runner) {
		return "devzone", nil
	}
	return "", fmt.Errorf(`no devzone services cluster identified: no cluster= line in the state, no "devzone" context in the kubeconfig`)
}

func declaresDevzoneContext(ctx context.Context, runner exec.Runner) bool {
	res, err := runner.Run(ctx, "kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Opts{})
	if err != nil || res.Code != 0 {
		return false
	}
	for _, name := range strings.Split(string(res.Stdout), "\n") {
		if strings.TrimSpace(name) == "devzone" {
			return true
		}
	}
	return false
}
