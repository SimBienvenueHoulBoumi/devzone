package podcmd

import (
	"context"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/agent"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// runAgent handles `devzone agent …` in Go (#878): identical behavior to the
// removed agent.sh, opencode/git/gh/kubectl through the injectable Runner.
func runAgent(ctx *cli.Context) int {
	root := devzoneRoot()
	opts := agent.Options{
		Runner:          ctx.Runner,
		Out:             ctx.Out,
		Err:             ctx.Err,
		DevcontainerDir: codeRoot(),
		Racine:          root,
		StateDir:        agentStateDir(),
		Starter:         agent.ExecSessionStarter{ReaperPath: reaperExecutable()},
	}
	if opts.DevcontainerDir == "" {
		opts.DevcontainerDir = root + "/.devcontainer"
	}
	if opts.StateDir == "" {
		opts.StateDir = homeLocalState()
	}
	return agent.Run(context.Background(), opts, ctx.Args)
}

// agentStateDir returns $DEVZONE_AGENT_STATE else ~/.local/state/oc-lancer.
func agentStateDir() string { return os.Getenv("DEVZONE_AGENT_STATE") }

func homeLocalState() string {
	home := os.Getenv("HOME")
	if home == "" {
		home = "."
	}
	return home + "/.local/state/oc-lancer"
}
