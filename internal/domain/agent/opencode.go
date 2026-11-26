package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
)

// OpenCodeLaunch starts opencode run in background appending to journal;
// KUBECONFIG setup. Shell opencode_launch. Returns started process.
func OpenCodeLaunch(ctx context.Context, r Runner, starter SessionStarter, folder, model, brief, journal, state string, local LocalModel) (SessionProcess, error) {
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
				res, _ := r.Run(ctx, "kubectl", []string{"config", "view", "--minify", "--flatten", "--context", "devzone"}, Opts{Env: []string{"KUBECONFIG=" + kubeConfig}})
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
	proc, err := starter.Start(cmd)
	if err != nil {
		journalFile.Close()
		return nil, err
	}
	// child has its own dup of the fd; parent's copy can close immediately
	journalFile.Close()
	return proc, nil
}

func fileSize(p string) int64 {
	info, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return info.Size()
}
