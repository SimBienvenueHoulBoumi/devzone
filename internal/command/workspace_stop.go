package command

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// The collaborators of "workspace stop" are injectable: a test answers kubectl
// and helm through commandWorkspaceRunner and the gh and kubectl calls of the
// GitOps repository through commandGitopsRunner, so it never reads a PATH.
var (
	commandWorkspaceRunner workspace.Runner = workspace.ExecRunner{}
	commandGitopsRunner    fexec.Runner     = fexec.ExecRunner{}
)

// workspaceStopCommand runs "workspace stop" in Go. When Argo CD holds the
// workspace, the Application file leaves the GitOps repository first, through
// the same library as the other Argo CD commands (GitHub and GitLab alike), and
// a refusal stops the command with its status, before the Application is deleted.
// Why: the file must leave first, or the root Application would recreate the
// Application at the next sync.
func workspaceStopCommand(ctx *cli.Context) int {
	opts := argocdOptions(ctx)
	opts.Runner = commandGitopsRunner
	remove := func(name string) int {
		return argocd.RemoveApplicationFile(context.Background(), opts, name)
	}
	return workspace.Stop(commandWorkspaceRunner, remove, ctx.Out, ctx.Err)
}
