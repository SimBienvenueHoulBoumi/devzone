package podcmd

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// runStateGitopsLine prints the Argo CD GitOps status line for the pod, matching
// state-gitops.sh. It reads the root Application URL; on refusal/absence it prints
// the workstation fallback line.
func runStateGitopsLine(ctx *cli.Context) int {
	ns := gitopsNamespace()
	res, err := ctx.Runner.Run(context.Background(), "kubectl", []string{
		"get", "application", "devzone", "-n", ns,
		"-o", "jsonpath={.spec.source.repoURL}", "--request-timeout=5s",
	}, exec.Opts{})
	if err == nil && res.Code == 0 {
		url := strings.TrimSpace(string(res.Stdout))
		if url != "" {
			fmt.Fprintf(ctx.Out, "  ○ argocd          GitOps repository: %s\n", url)
			return 0
		}
	}
	fmt.Fprintln(ctx.Out, "  ○ argocd          managed from the workstation: devzone workspace argocd status")
	return 0
}

// gitopsNamespace resolves the Argo CD namespace like GITOPS_NS in shell.
func gitopsNamespace() string {
	if v := strings.TrimSpace(getenv("GITOPS_NS")); v != "" {
		return v
	}
	return "devzone-argocd"
}

// getenv isolates os.Getenv for small helpers.
func getenv(k string) string { return strings.TrimSpace(os.Getenv(k)) }
