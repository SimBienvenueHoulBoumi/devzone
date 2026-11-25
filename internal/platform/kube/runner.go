// Package kube wraps the kubectl calls needed by the cluster domain, always
// through the framework runner so that tests can replace the real process.
package kube

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

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

// RunWithInput executes kubectl with KUBECONFIG set to conf and input as its
// standard input, for the create | apply -f - pipeline of the account library.
func (k Kube) RunWithInput(ctx context.Context, conf string, input []byte, args ...string) (exec.Result, error) {
	opts := exec.Opts{Env: []string{"KUBECONFIG=" + conf}, Stdin: bytes.NewReader(input)}
	return k.runner().Run(ctx, "kubectl", args, opts)
}

// adminRun runs kubectl on the administrator context: the kubeconfig holding
// that context, with --context passed explicitly as in account_admin. It also
// returns the kubeconfig used and the resolved context, so that a create output
// can be piped into apply with the same context and file.
func (k Kube) adminRun(ctx context.Context, contextName string, args ...string) (string, string, exec.Result, error) {
	name := contextName
	if name == "" {
		res, err := k.Run(ctx, accountKubeconfigPath(), "config", "current-context")
		if err == nil && res.Code == 0 {
			name = strings.TrimSpace(string(res.Stdout))
		}
	}
	conf := k.AdminKubeconfig(name)
	if name != "" {
		args = append([]string{"--context", name}, args...)
	}
	res, err := k.Run(ctx, conf, args...)
	return conf, name, res, err
}

// adminApply creates a resource as administrator and applies the YAML it
// produced, exactly like the create ... | apply -f - pipeline of the shell.
func (k Kube) adminApply(ctx context.Context, contextName string, args ...string) error {
	conf, name, res, err := k.adminRun(ctx, contextName, args...)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return errors.New("cannot create the resource with kubectl")
	}
	applyArgs := []string{"apply", "-f", "-"}
	if name != "" {
		applyArgs = append([]string{"--context", name}, applyArgs...)
	}
	res, err = k.RunWithInput(ctx, conf, res.Stdout, applyArgs...)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return errors.New("cannot apply the resource with kubectl")
	}
	return nil
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
