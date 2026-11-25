package kube

import (
	"context"
	"strings"
)

// Setup prepares the limited account of the services context: the devzone-system
// namespace and the devzone-agent ServiceAccount (idempotent, resumed at startup
// and at each installation).
func (k Kube) Setup(ctx context.Context, contextName string) error {
	if err := k.adminApply(ctx, contextName, "create", "namespace", accountNamespace,
		"--dry-run=client", "-o", "yaml"); err != nil {
		return err
	}
	return k.adminApply(ctx, contextName, "-n", accountNamespace, "create", "serviceaccount",
		accountServiceAccount, "--dry-run=client", "-o", "yaml")
}

// Allow allows the limited account in namespace: devzone-agent RoleBinding to
// the edit ClusterRole (read, write, secrets, NetworkPolicies — no RBAC, no
// quotas), set with the admin context after the namespace is created. The
// account is set up first if missing: an installation on a still blank cluster
// makes the account usable at the next token renewal.
func (k Kube) Allow(ctx context.Context, contextName string, namespace string) error {
	if err := k.Setup(ctx, contextName); err != nil {
		return err
	}
	return k.allow(ctx, contextName, namespace)
}

// allow sets the RoleBinding of the limited account in namespace, once the
// namespace is created.
func (k Kube) allow(ctx context.Context, contextName string, namespace string) error {
	return k.adminApply(ctx, contextName, "-n", namespace, "create", "rolebinding", accountServiceAccount,
		"--clusterrole=edit", "--serviceaccount="+accountNamespace+":"+accountServiceAccount,
		"--dry-run=client", "-o", "yaml")
}

// CatchUp sets the RoleBinding of the limited account in each existing
// devzone namespace: idempotent, for the installations prior to the limited
// account. A namespace listing that cannot be read is not an error: the shell
// original ignored it too.
func (k Kube) CatchUp(ctx context.Context, contextName string) error {
	_, _, res, err := k.adminRun(ctx, contextName, "get", "namespaces", "-l", accountLabel, "-o", "name")
	if err != nil || res.Code != 0 {
		return nil
	}
	for _, line := range strings.Split(string(res.Stdout), "\n") {
		namespace := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "namespace/"))
		if namespace == "" {
			continue
		}
		if err := k.allow(ctx, contextName, namespace); err != nil {
			return err
		}
	}
	return nil
}
