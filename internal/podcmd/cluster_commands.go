package podcmd

import (
	"context"
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/cluster"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// manageOptions builds the options of the cluster commands from the pod context.
func manageOptions(ctx *cli.Context) cluster.ManageOptions {
	return cluster.ManageOptions{
		Runner:    ctx.Runner,
		Out:       ctx.Out,
		Err:       ctx.Err,
		Stdin:     ctx.Stdin,
		StatePath: statePath(),
		Remote:    kubeRemoteConfirmation(),
		Install: func() int {
			return runPostgres(&cli.Context{
				Args: []string{"install"}, Out: ctx.Out, Err: ctx.Err,
				Stdin: ctx.Stdin, Runner: ctx.Runner,
			})
		},
	}
}

// kubeRemoteConfirmation returns the test/CI confirmation of a remote cluster.
func kubeRemoteConfirmation() string {
	return os.Getenv("DEVZONE_CLUSTER_REMOTE")
}

// runClusters shows the connected clusters in Go.
func runClusters(ctx *cli.Context) int {
	return kube.Kube{Runner: ctx.Runner}.View(context.Background(), kube.SavedContext(statePath()), ctx.Out, ctx.Err)
}

// runMetrics installs or removes metrics-server. With Argo CD active and no
// explicit context, the install is an Application and remove also deletes it;
// explicit contexts keep the direct Go installer, and the Application is only
// ever the devzone one.
func runMetrics(ctx *cli.Context) int {
	held := metricsHeldByArgoCD(ctx)
	if held && len(ctx.Args) == 0 {
		return metricsApplication(ctx, "on")
	}
	remove := len(ctx.Args) > 0 && ctx.Args[0] == "remove"
	code := kube.Kube{Runner: ctx.Runner}.Metrics(context.Background(), ctx.Args, ctx.Out, ctx.Err)
	if remove && held {
		if appCode := metricsApplication(ctx, "off"); appCode != 0 {
			code = appCode
		}
	}
	return code
}

// runUse switches the working cluster without changing the services cluster.
func runUse(ctx *cli.Context) int {
	return cluster.Use(context.Background(), manageOptions(ctx), ctx.Args)
}

// runKube exposes the read-only cluster checks used by the shell status and
// prompt, so those callers never source a shell library again.
func runKube(ctx *cli.Context) int {
	if len(ctx.Args) == 0 {
		fmt.Fprintln(ctx.Err, "devzone kube: saved | local CTX | reachable CTX | prompt")
		return 1
	}
	k := kube.Kube{Runner: ctx.Runner}
	switch ctx.Args[0] {
	case "saved":
		fmt.Fprintln(ctx.Out, kube.SavedContext(statePath()))
		return 0
	case "local":
		if len(ctx.Args) != 2 {
			return 2
		}
		if k.IsLocal(ctx.Args[1]) {
			return 0
		}
		return 1
	case "reachable":
		if len(ctx.Args) != 2 {
			return 2
		}
		if k.ClusterReachable(context.Background(), ctx.Args[1]) {
			return 0
		}
		return 1
	case "choose":
		wanted, confirm := "", ""
		for i := 0; i < len(ctx.Args); i++ {
			if ctx.Args[i] == "--confirm" {
				if i+1 >= len(ctx.Args) {
					fmt.Fprintln(ctx.Err, "devzone : --confirm needs a context")
					return 2
				}
				i++
				confirm = ctx.Args[i]
			} else {
				wanted = ctx.Args[i]
			}
		}
		choice := kube.ChooseOptions{Wanted: wanted, Confirm: confirm,
			Saved: kube.SavedContext(statePath()), Remote: kubeRemoteConfirmation(),
			Interactive: os.Getenv("DEVZONE_INTERACTIVE") == "1", Stdin: ctx.Stdin,
			Out: ctx.Out, Err: ctx.Err}
		name, code := k.Choose(context.Background(), choice)
		if code != 0 {
			return code
		}
		fmt.Fprintln(ctx.Out, name)
		return 0
	case "save":
		if len(ctx.Args) != 2 {
			return 2
		}
		if err := kube.SaveContext(statePath(), ctx.Args[1]); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "prompt":
		if err := k.Prompt(context.Background(), ctx.Out); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(ctx.Err, "devzone kube: unknown argument: %s\n", ctx.Args[0])
		return 2
	}
}
