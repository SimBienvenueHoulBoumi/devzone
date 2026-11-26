package podcmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

const defaultModules = "ai kubernetes gitlab postgres argocd mysql"

// runState handles "devzone state ..." subcommands in Go, replacing the shell
// state scripts while keeping the same lock, backup and recovery semantics.
func runState(ctx *cli.Context) int {
	if len(ctx.Args) == 0 {
		fmt.Fprintln(ctx.Err, "devzone state: write|remove|replace|init|recovery-mark|recovery-wait|recovery-pending|recovery-confirm|catalog-sync|gitops-line|json")
		return 1
	}
	st := state.At(statePath())
	switch ctx.Args[0] {
	case "write":
		if len(ctx.Args) != 3 {
			fmt.Fprintln(ctx.Err, "devzone state write: key value")
			return 2
		}
		if err := st.Set(ctx.Args[1], ctx.Args[2]); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "remove":
		if len(ctx.Args) != 2 {
			fmt.Fprintln(ctx.Err, "devzone state remove: key")
			return 2
		}
		if err := st.Delete(ctx.Args[1]); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "replace":
		if len(ctx.Args) != 2 {
			fmt.Fprintln(ctx.Err, "devzone state replace: file")
			return 2
		}
		if err := st.Replace(ctx.Args[1]); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "init":
		mods := modulesFromArgs(ctx.Args[1:])
		if err := st.Init(mods, osRunner(ctx), os.Getenv("HOME"), credentialsFound, warnFunc(ctx)); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "recovery-mark":
		if err := st.RecoveryMark(); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "recovery-wait":
		if st.RecoveryWait() {
			return 0
		}
		return 1
	case "recovery-pending":
		if st.RecoveryPending() {
			return 0
		}
		return 1
	case "recovery-confirm":
		if err := st.RecoveryConfirm(); err != nil {
			fmt.Fprintln(ctx.Err, err)
			return 1
		}
		return 0
	case "catalog-sync":
		return runStateCatalogSync(ctx, st)
	case "gitops-line":
		return runStateGitopsLine(ctx)
	case "json":
		return runStateJSON(ctx, st)
	default:
		fmt.Fprintf(ctx.Err, "devzone state: unknown subcommand: %s\n", ctx.Args[0])
		return 1
	}
}

// statePath resolves the state file path from DEVZONE_STATE, like the shell.
func statePath() string {
	if v := os.Getenv("DEVZONE_STATE"); v != "" {
		return v
	}
	root := os.Getenv("DEVZONE_ROOT")
	if root == "" {
		root = os.Getenv("HOME")
	}
	return filepath.Join(root, ".devzone.modules")
}

// modulesFromArgs parses modules from args or returns the default module list.
func modulesFromArgs(args []string) []string {
	if len(args) == 0 {
		return strings.Fields(defaultModules)
	}
	return args
}

// osRunner adapts the CLI runner to the state.Runner signature.
func osRunner(ctx *cli.Context) state.Runner {
	return func(name string, args ...string) (string, string, error) {
		res, err := ctx.Runner.Run(context.Background(), name, args, exec.Opts{})
		if err != nil {
			return string(res.Stdout), string(res.Stderr), err
		}
		if res.Code != 0 {
			return string(res.Stdout), string(res.Stderr), fmt.Errorf("exit %d", res.Code)
		}
		return string(res.Stdout), string(res.Stderr), nil
	}
}

// credentialsFound reports whether shared AI credentials exist, like state_init.
func credentialsFound() bool {
	home := os.Getenv("HOME")
	for _, p := range []string{filepath.Join(home, ".claude", ".credentials.json"), filepath.Join(home, ".local", "share", "opencode", "auth.json")} {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

// warnFunc returns a warning writer matching the shell stderr messages.
func warnFunc(ctx *cli.Context) func(string) {
	return func(msg string) { fmt.Fprintln(ctx.Err, msg) }
}
