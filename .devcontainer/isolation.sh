#!/usr/bin/env bash
# Network isolation and access authorization between devzone namespaces.
# File <= 250 lines: functions namespace_isolate, allow, forbid.
# These functions modify NetworkPolicies in the Kubernetes cluster.
# Loaded by argocd.sh, catalog.sh, the mysql and postgres Go modules, gitlab.sh; shipped with the package.

# Sets an isolating NetworkPolicy in a namespace.
# Only the pods of the same namespace can reach the services.
namespace_isolate() {
    local ns="${1:-}"
    [ -n "$ns" ] || { echo "devzone : namespace missing" >&2; return 2; }

    kubectl --context devzone -n "$ns" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
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
EOF
}

# Adds a namespaceSelector rule to the NetworkPolicy of the target namespace,
# allowing access from outside this namespace.
# Without this rule, an application in another namespace cannot reach the
# devzone services (postgres, etc.).
allow() {
    local target_ns="${1:-}" patch output
    [ -n "$target_ns" ] || { echo "devzone : target namespace missing" >&2; return 2; }

    kubectl --context devzone -n "$target_ns" get networkpolicy devzone-meme-namespace \
        -o yaml 2>/dev/null | kubectl --context devzone -n "$target_ns" apply -f - >/dev/null 2>&1 ||
        { echo "devzone : cannot apply the isolating NetworkPolicy in $target_ns" >&2; return 1; }

    patch="$(jq -nc '{"spec":{"ingress":[{"from":[{"podSelector":{},
        "namespaceSelector":{"matchLabels":{"app.kubernetes.io/managed-by":"devzone"}}}]}]}}')"
    if ! output="$(kubectl --context devzone -n "$target_ns" patch networkpolicy devzone-meme-namespace \
        -p "$patch" 2>&1)"; then
        echo "devzone : cannot allow access to $target_ns : $output" >&2
        return 1
    fi

    echo "devzone : rule allowed to $target_ns"
}

# Removes the namespaceSelector rule from the NetworkPolicy,
# blocking access again from the given namespace.
forbid() {
    local target_ns="${1:-}" patch output
    [ -n "$target_ns" ] || { echo "devzone : target namespace missing" >&2; return 2; }

    patch="$(jq -nc '{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}')"
    if ! output="$(kubectl --context devzone -n "$target_ns" patch networkpolicy devzone-meme-namespace \
        -p "$patch" 2>&1)"; then
        echo "devzone : cannot forbid access to $target_ns : $output" >&2
        return 1
    fi

    echo "devzone : rule forbidden to $target_ns"
}
