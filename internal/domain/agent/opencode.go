package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// kubeconfigRunner makes a runner read the given kubeconfig on context queries,
// so the shared chooser checks the same file as the following kubectl view.
type kubeconfigRunner struct {
	Runner
	config string
}

// Run adds the workstation kubeconfig to a context query and delegates the run.
func (r kubeconfigRunner) Run(ctx context.Context, name string, args []string, opts Opts) (Result, error) {
	if len(opts.Env) == 0 {
		opts.Env = []string{"KUBECONFIG=" + r.config}
	}
	return r.Runner.Run(ctx, name, args, opts)
}

// OpenCodeLaunch starts opencode run in background appending to journal;
// KUBECONFIG setup. Shell opencode_launch. Returns started process.
func OpenCodeLaunch(ctx context.Context, r Runner, lookPath func(string) (string, error), starter SessionStarter, folder, model, brief, journal, state string, local LocalModel) (SessionProcess, error) {
	briefText := readFileString(brief)
	args := []string{"run", "--print-logs", "--log-level", "ERROR", "--auto", "-m", local.ModelRef(model), briefText}
	agentKube := filepath.Join(state, "kubeconfig")
	var env []string
	var unset []string
	if AgentInPod() {
		unset = []string{"KUBECONFIG"}
		env = []string{"DEVZONE_AGENT_SESSION=1"}
	} else {
		home := os.Getenv("HOME")
		kubeConfig := filepath.Join(home, ".kube", "config")
		if home != "" && fileExists(kubeConfig) {
			_ = os.WriteFile(agentKube, nil, 0o600)
			if r != nil {
				flag := fexec.DevzoneContextFlag(ctx, kubeconfigRunner{Runner: r, config: kubeConfig}, "--context")
				args := append([]string{"config", "view", "--minify", "--flatten"}, flag...)
				res, _ := r.Run(ctx, "kubectl", args, Opts{Env: []string{"KUBECONFIG=" + kubeConfig}})
				if res.Code == 0 && len(strings.TrimSpace(string(res.Stdout))) > 0 {
					_ = os.WriteFile(agentKube, res.Stdout, 0o600)
				} else {
					_ = os.WriteFile(agentKube, nil, 0o600)
				}
			}
			os.Chmod(agentKube, 0o600)
			if size := fileSize(agentKube); size == 0 {
				appendLine(journal, "=== kubernetes: no devzone context, session without access")
			}
		} else {
			_ = os.WriteFile(agentKube, nil, 0o600)
			os.Chmod(agentKube, 0o600)
		}
		env = []string{"KUBECONFIG=" + agentKube, "DEVZONE_AGENT_SESSION=1"}
	}
	if starter == nil {
		starter = ExecSessionStarter{}
	}
	journalFile, err := os.OpenFile(journal, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	cmd := SessionCmd{
		Name:   "opencode",
		Args:   args,
		Dir:    folder,
		Env:    env,
		Unset:  unset,
		Stdin:  nil, // </dev/null
		Stdout: journalFile,
		Stderr: journalFile,
	}
	proc, err := starter.Start(noCoreSession(cmd, lookPath))
	if err != nil {
		journalFile.Close()
		return nil, err
	}
	// child has its own dup of the fd; parent's copy can close immediately
	journalFile.Close()
	return proc, nil
}

// noCoreSession wraps a session in a shell that sets the core file size limit
// to zero before replacing itself with the target process. Without this guard a
// crashed opencode writes a multi-gigabyte core file into the worktree. The
// lookup is injected so tests never need a fake binary in PATH; without a shell
// the direct command is kept, since there is no ulimit to set on that host.
func noCoreSession(cmd SessionCmd, lookPath func(string) (string, error)) SessionCmd {
	if lookPath == nil {
		return cmd
	}
	shell, err := lookPath("bash")
	if err != nil || shell == "" {
		return cmd
	}
	wrapped := cmd
	wrapped.Name = shell
	wrapped.Args = append([]string{"-c", `ulimit -c 0 || exit 1; exec "$@"`, cmd.Name, cmd.Name}, cmd.Args...)
	return wrapped
}

func fileSize(p string) int64 {
	info, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return info.Size()
}
