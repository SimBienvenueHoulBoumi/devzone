package command

import (
	"bytes"
	"context"
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// kubeReadyCommand answers the shell callers that used to source a readiness
// script (#884): the reason goes to stdout and status 0 means the cluster
// answers. Keeping it internal avoids adding an entry to the user help.
func kubeReadyCommand(ctx *cli.Context) int {
	hint := false
	for _, arg := range ctx.Args {
		if arg != "--hint" {
			fmt.Fprintln(ctx.Err, "✖ usage: devzone kube-ready [--hint]")
			return 2
		}
		hint = true
	}
	runner := ctx.Runner
	if runner == nil {
		runner = fexec.ExecRunner{}
	}
	reason, ready := workspace.KubeReady(kubeRunner{runner}, hint)
	if reason != "" {
		fmt.Fprintln(ctx.Out, reason)
	}
	if ready {
		return 0
	}
	return 1
}

// kubeRunner adapts the command runner to the kubectl and helm runner used by
// the workspace check, so tests can drive the check with the shared fake runner.
type kubeRunner struct {
	runner fexec.Runner
}

// Kubectl runs kubectl through the command runner and returns its exit status.
func (k kubeRunner) Kubectl(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return k.run("kubectl", args, stdin, stdout, stderr)
}

// Helm runs helm through the command runner and returns its exit status.
func (k kubeRunner) Helm(args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return k.run("helm", args, stdin, stdout, stderr)
}

// run carries one command with its streams through the injected runner.
func (k kubeRunner) run(name string, args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	res, err := k.runner.Run(context.Background(), name, args, fexec.Opts{Stdin: stdin})
	_, _ = io.Copy(stdout, bytes.NewReader(res.Stdout))
	_, _ = io.Copy(stderr, bytes.NewReader(res.Stderr))
	return res.Code, err
}
