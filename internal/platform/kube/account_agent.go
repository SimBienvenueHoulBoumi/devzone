package kube

import (
	"context"
	"errors"
	"os"
	"path/filepath"
)

// AgentConfig writes the reduced kubeconfig of the agents: the devzone context
// only, current context set to it, for the assistants that hold the limited
// account (Claude Code, #844). The contexts are read from the account
// kubeconfig, never from the file being written: the view goes to a temporary
// file of the same folder, moved in place (atomic, mode 600); a failure empties
// the target and returns an error.
func (k Kube) AgentConfig(ctx context.Context) error {
	conf := agentKubeconfigPath()
	tmp, err := os.CreateTemp(filepath.Dir(conf), ".agent.config.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return emptyAgentConfig(conf, err)
	}
	res, err := k.Run(ctx, accountKubeconfigPath(), "config", "view", "--minify", "--flatten", "--context", accountContextName)
	if err == nil && res.Code != 0 {
		err = errors.New("cannot minify the agent kubeconfig")
	}
	if err == nil {
		_, err = tmp.Write(res.Stdout)
	}
	if err != nil {
		_ = tmp.Close()
		return emptyAgentConfig(conf, err)
	}
	if err := tmp.Close(); err != nil {
		return emptyAgentConfig(conf, err)
	}
	res, err = k.Run(ctx, tmpName, "config", "use-context", accountContextName)
	if err == nil && res.Code != 0 {
		err = errors.New("cannot set the agent context")
	}
	if err != nil {
		return emptyAgentConfig(conf, err)
	}
	if err := os.Rename(tmpName, conf); err != nil {
		return err
	}
	return os.Chmod(conf, 0o600)
}

// emptyAgentConfig truncates the target kubeconfig when the reduced view or its
// context write failed, as the shell original did with a redirection to the
// target file.
func emptyAgentConfig(conf string, err error) error {
	_ = os.WriteFile(conf, nil, 0o600)
	return err
}
