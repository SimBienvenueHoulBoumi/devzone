package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Run executes `devzone agent ...`; returns exit code. Identical subcommands,
// outputs, journals, state, codes as agent.sh. opencode/git/gh/kubectl/ps/curl/
// getent go through opts.Runner; ai check calls devzone is-enabled via Runner.
func Run(ctx context.Context, opts Options, args []string) int {
	errOut := opts.err()
	out := opts.out()
	if opts.DevcontainerDir == "" {
		opts.DevcontainerDir = defaultDevcontainerDir()
	}
	if opts.Racine == "" {
		opts.Racine = defaultRacine(opts.DevcontainerDir)
	}
	if opts.StateDir == "" {
		opts.StateDir = defaultStateDir()
	}
	if opts.Home == "" {
		opts.Home = os.Getenv("HOME")
	}
	if len(args) == 0 {
		fmt.Fprint(out, AgentHelp())
		return 2
	}
	switch args[0] {
	case "status":
		AgentPodStatus(ctx, opts.runner(), out)
		return 0
	case "state":
		if len(args) > 1 && args[1] == "--json" {
			fmt.Fprintln(out, AgentStateJSON(ctx, opts.runner(), opts.Racine, opts.StateDir, psArgs(ctx, opts.runner()), nowClock(opts)))
		} else {
			fmt.Fprint(out, AgentState(opts.Racine, opts.StateDir, nowClock(opts), psArgs(ctx, opts.runner()), RightsAlerts(opts.StateDir)))
		}
		return 0
	case "release":
		if len(args) < 2 || args[1] == "" {
			fmt.Fprint(errOut, AgentHelp())
			return 2
		}
		ExclusionClear(opts.StateDir, args[1])
		return 0
	case "-h", "--help", "help":
		fmt.Fprint(out, AgentHelp())
		return 0
	case "":
		fmt.Fprint(out, AgentHelp())
		return 2
	}
	rest := append([]string{}, args...)
	modelList := ""
	// --model
	if rest[0] == "--model" {
		if len(rest) < 2 || rest[1] == "" {
			fmt.Fprint(errOut, AgentHelp())
			return 2
		}
		modelList = rest[1]
		rest = rest[2:]
	}
	// --pod
	if len(rest) > 0 && rest[0] == "--pod" {
		if modelList != "" {
			return refuse(errOut, "--model is not supported with --pod")
		}
		rest = rest[1:]
		if len(rest) < 2 || rest[0] == "" || rest[1] == "" {
			fmt.Fprint(errOut, AgentHelp())
			return 2
		}
		return AgentPodLaunch(ctx, opts.runner(), opts.clock(), rest[0], rest[1], opts.StateDir, errOut)
	}
	localMode := false
	if len(rest) > 0 && rest[0] == "--local" {
		localMode = true
		rest = rest[1:]
	}
	if len(rest) < 2 {
		fmt.Fprint(errOut, AgentHelp())
		return 2
	}
	folder, brief := rest[0], rest[1]
	launchOpts := opts
	launchOpts.ModelList = modelList
	launchOpts.LocalMode = localMode
	if !localMode && WorkspaceAvailable(ctx, opts.runner()) {
		return AgentWorkspace(ctx, opts.runner(), out, errOut, folder, brief, opts.Racine, modelList, JournalOf(opts.Racine, filepath.Base(folder)))
	}
	return AgentLaunch(ctx, launchOpts, folder, brief)
}

func psArgs(ctx context.Context, r Runner) string {
	if r == nil {
		return ""
	}
	res, err := r.Run(ctx, "ps", []string{"-eo", "args="}, Opts{})
	if err != nil {
		return ""
	}
	return string(res.Stdout)
}

func nowClock(opts Options) time.Time { return opts.clock().Now() }

func defaultStateDir() string {
	if v := os.Getenv("DEVZONE_AGENT_STATE"); v != "" {
		return v
	}
	home := os.Getenv("HOME")
	if home == "" {
		home = "."
	}
	return filepath.Join(home, ".local", "state", "oc-lancer")
}

func defaultDevcontainerDir() string {
	// $ICI: folder of agent.sh (.devcontainer); here env or parent of executable.
	if v := os.Getenv("DEVZONE_DEVCONTAINER"); v != "" {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Dir(exe)
	}
	wd, _ := os.Getwd()
	return filepath.Join(wd, ".devcontainer")
}

func defaultRacine(devcontainerDir string) string {
	if v := os.Getenv("DEVZONE_ROOT"); v != "" {
		return v
	}
	return filepath.Dir(devcontainerDir)
}
