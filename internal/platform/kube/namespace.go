package kube

import (
	"bytes"
	"context"
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// NamespaceCreate creates and labels a devzone namespace as administrator,
// then allows the limited account in it, as account_namespace does.
func (k Kube) NamespaceCreate(ctx context.Context, contextName, ns string, errOut io.Writer) error {
	if err := k.applyGenerated(ctx, contextName, []string{"create", "namespace", ns, "--dry-run=client", "-o", "yaml"}, errOut); err != nil {
		return err
	}
	res, err := k.AccountAdmin(ctx, contextName, "label", "namespace", ns, clusterLabel(), "--overwrite")
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return k.AccountAllow(ctx, contextName, ns, errOut)
}

// AccountAllow sets the devzone-agent RoleBinding in ns with the admin context.
func (k Kube) AccountAllow(ctx context.Context, contextName, ns string, errOut io.Writer) error {
	if err := k.applyGenerated(ctx, contextName, []string{
		"create", "namespace", "devzone-system", "--dry-run=client", "-o", "yaml"}, errOut); err != nil {
		return err
	}
	if err := k.applyGenerated(ctx, contextName, []string{
		"-n", "devzone-system", "create", "serviceaccount", "devzone-agent",
		"--dry-run=client", "-o", "yaml"}, errOut); err != nil {
		return err
	}
	return k.applyGenerated(ctx, contextName, []string{
		"-n", ns, "create", "rolebinding", "devzone-agent",
		"--clusterrole=edit", "--serviceaccount=devzone-system:devzone-agent",
		"--dry-run=client", "-o", "yaml"}, errOut)
}

// applyGenerated runs a create command, then applies the manifest it produced
// on standard input, as the pipelines of kube-account.sh do.
func (k Kube) applyGenerated(ctx context.Context, contextName string, createArgs []string, errOut io.Writer) error {
	created, err := k.AccountAdmin(ctx, contextName, createArgs...)
	if err != nil {
		return err
	}
	if created.Code != 0 {
		return &ExitError{Code: created.Code, Stderr: string(created.Stderr)}
	}
	res, err := k.AccountAdmin(ctx, contextName, "apply", "-f", "-")
	if err != nil {
		return err
	}
	if res.Code != 0 {
		if errOut != nil {
			_, _ = io.WriteString(errOut, string(res.Stderr))
		}
		return &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return nil
}

// NamespaceIsolate applies the isolating NetworkPolicy of isolation.sh in ns.
func (k Kube) NamespaceIsolate(ctx context.Context, ns string, errOut io.Writer) error {
	manifest := `apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: devzone-meme-namespace
  labels:
    app.kubernetes.io/managed-by: devzone
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
`
	res, err := k.runner().Run(ctx, "kubectl",
		append(exec.DevzoneContextFlag(ctx, k.runner(), "--context"), "-n", ns, "apply", "-f", "-"),
		exec.Opts{Stdin: bytes.NewBufferString(manifest)})
	if err != nil {
		return err
	}
	if res.Code != 0 {
		if errOut != nil {
			fmt.Fprint(errOut, string(res.Stderr))
		}
		return &ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return nil
}
