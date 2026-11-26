// Package kube wraps the kubectl calls needed by the cluster domain, always
// through the framework runner so that tests can replace the real process.
package kube

import (
	"context"
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// DefaultRunner is the runner used by the package helpers; tests replace it.
var DefaultRunner exec.Runner = exec.ExecRunner{}

// Kube holds the runner of one set of kubectl calls.
type Kube struct {
	Runner exec.Runner
}

// runner returns the runner of this instance, or the package default.
func (k Kube) runner() exec.Runner {
	if k.Runner != nil {
		return k.Runner
	}
	if DefaultRunner != nil {
		return DefaultRunner
	}
	return exec.ExecRunner{}
}

// Run executes kubectl with KUBECONFIG set to conf, never with the inherited
// combined configuration of the shell.
func (k Kube) Run(ctx context.Context, conf string, args ...string) (exec.Result, error) {
	return k.runner().Run(ctx, "kubectl", args, exec.Opts{Env: []string{"KUBECONFIG=" + conf}})
}

// home returns the home directory of the current user, or an empty string.
func home() string {
	if dir := os.Getenv("HOME"); dir != "" {
		return dir
	}
	dir, _ := os.UserHomeDir()
	return dir
}

// configPath joins the home directory and the name of a kubeconfig file.
func configPath(name string) string {
	return filepath.Join(home(), ".kube", name)
}
