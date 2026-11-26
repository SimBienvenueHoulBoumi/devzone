package kube

import (
	"context"
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// raw runs a kubectl configuration command with the inherited environment, as
// the shell did before the port: no KUBECONFIG override for these queries.
func (k Kube) raw(ctx context.Context, args ...string) (exec.Result, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	return k.runner().Run(ctx, "kubectl", args, exec.Opts{})
}

// ConfigContexts lists the context names of the inherited kubeconfig.
func (k Kube) ConfigContexts(ctx context.Context) ([]string, error) {
	res, err := k.raw(ctx, "config", "get-contexts", "-o", "name")
	if err != nil {
		return nil, err
	}
	if res.Code != 0 {
		return nil, &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	var names []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	return names, nil
}

// HostContexts lists the context names of one explicit kubeconfig file.
func (k Kube) HostContexts(ctx context.Context, conf string) ([]string, error) {
	if conf == "" || !isFile(conf) {
		return nil, nil
	}
	res, err := k.Run(ctx, conf, "config", "get-contexts", "-o", "name")
	if err != nil {
		return nil, err
	}
	if res.Code != 0 {
		return nil, &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	var names []string
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	return names, nil
}

// CurrentContext returns the context kubectl currently uses.
func (k Kube) CurrentContext(ctx context.Context) string {
	res, err := k.raw(ctx, "config", "current-context")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// HostCurrentContext returns the current context of an explicit kubeconfig.
func (k Kube) HostCurrentContext(ctx context.Context, conf string) string {
	if conf == "" || !isFile(conf) {
		return ""
	}
	res, err := k.Run(ctx, conf, "config", "current-context")
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// ContextNamespace returns the namespace of a context, or an empty string.
func (k Kube) ContextNamespace(ctx context.Context, name string) string {
	query := fmt.Sprintf(`jsonpath={.contexts[?(@.name==%q)].context.namespace}`, name)
	res, err := k.raw(ctx, "config", "view", "-o", query)
	if err != nil || res.Code != 0 {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// UseContext switches the working kubectl context.
func (k Kube) UseContext(ctx context.Context, name string) error {
	res, err := k.raw(ctx, "config", "use-context", name)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return nil
}

// SetNamespace sets the namespace of one context in the kubeconfig.
func (k Kube) SetNamespace(ctx context.Context, name, namespace string) error {
	res, err := k.raw(ctx, "config", "set-context", name, "--namespace", namespace)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return nil
}

// ReachableTimeout reports whether the API server of ctx answers within the
// requested timeout, as the --request-timeout checks of the shell did.
func (k Kube) ReachableTimeout(ctx context.Context, name, timeout string) bool {
	res, err := k.raw(ctx, "--context", name, "--request-timeout="+timeout, "get", "--raw", "/readyz")
	return err == nil && res.Code == 0
}
