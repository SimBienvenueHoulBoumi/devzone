package kube

import (
	"context"
	"io"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// AccountContext returns the admin context of an installation: the services
// cluster saved in the state, or the current kubectl context when no cluster
// has been chosen yet. It mirrors account_context of kube-account.sh.
func (k Kube) AccountContext(saved string) string {
	if saved != "" {
		return saved
	}
	res, err := k.runner().Run(context.Background(), "kubectl", []string{"config", "current-context"}, exec.Opts{})
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// AccountContext returns the admin context with the default runner.
func AccountContext(saved string) string { return Kube{}.AccountContext(saved) }

// AccountAdmin runs kubectl through the administrator context. The explicit
// kubeconfig is the one that holds the context, never the combined KUBECONFIG
// of the shell, as in account_admin of kube-account.sh.
func (k Kube) AccountAdmin(ctx context.Context, contextName string, args ...string) (exec.Result, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	conf := k.AdminKubeconfig(contextName)
	full := []string{"--kubeconfig=" + conf}
	if contextName != "" {
		full = append(full, "--context", contextName)
	}
	full = append(full, args...)
	return k.runner().Run(ctx, "kubectl", full, exec.Opts{})
}

// AccountAdminInput is AccountAdmin with data on standard input, for the
// create | apply pipelines of the installers.
func (k Kube) AccountAdminInput(ctx context.Context, contextName string, stdin io.Reader, args ...string) (exec.Result, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	conf := k.AdminKubeconfig(contextName)
	full := []string{"--kubeconfig=" + conf}
	if contextName != "" {
		full = append(full, "--context", contextName)
	}
	full = append(full, args...)
	return k.runner().Run(ctx, "kubectl", full, exec.Opts{Stdin: stdin})
}

// AccountRemove deletes the limited account RoleBinding of ns with the admin
// context. A missing RoleBinding is not an error, as in account_remove.
func (k Kube) AccountRemove(ctx context.Context, contextName, ns string) error {
	res, err := k.AccountAdmin(ctx, contextName,
		"-n", ns, "delete", "rolebinding", "devzone-agent", "--ignore-not-found")
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return nil
}

// ExitError reports a non-zero status of an external command.
type ExitError struct {
	Code   int
	Stderr string
}

// Error implements the error interface.
func (e *ExitError) Error() string {
	return strings.TrimSpace(e.Stderr)
}
