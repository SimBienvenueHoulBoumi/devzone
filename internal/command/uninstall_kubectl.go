package command

import (
	"context"
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

func kubectlLines(ctx context.Context, runner exec.Runner, kubeCtx string, args ...string) ([]string, error) {
	full := append([]string{"--context", kubeCtx}, args...)
	res, err := runner.Run(ctx, "kubectl", full, exec.Opts{})
	if err != nil {
		return nil, fmt.Errorf("kubectl %s: %w", strings.Join(full, " "), err)
	}
	if res.Code != 0 {
		if strings.Contains(string(res.Stderr), "doesn't have a resource type") {
			return nil, fmt.Errorf("kubectl %s: %w", strings.Join(full, " "), errMissingResourceType)
		}
		return nil, fmt.Errorf("kubectl %s: exit %d: %s", strings.Join(full, " "), res.Code, strings.TrimSpace(string(res.Stderr)))
	}
	lines := []string{}
	for _, l := range strings.Split(strings.TrimSpace(string(res.Stdout)), "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			lines = append(lines, l)
		}
	}
	return lines, nil
}
