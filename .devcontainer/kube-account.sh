#!/usr/bin/env bash
# Limited Kubernetes account (#430): the devzone context (projects, relays,
# agents) can only act in the devzone-* namespaces. The account is the
# ServiceAccount devzone-agent of the devzone-system namespace, bound to the
# edit ClusterRole (no RBAC, no quotas) in each devzone namespace by a
# RoleBinding, with a 24 h TokenRequest token renewed at startup (startup.sh),
# by « devzone repair » and by the summary before expiry. The installers alone
# use the admin context (host context in ~/.kube/hote.config, kind cluster in
# ~/.kube/config); the shells use ~/.kube/config and the agents the limited
# ~/.kube/agent.config (devzone context only, #844).
# Library sourced by cluster.sh; the token cycle itself is ported to Go
# (devzone account token / devzone account fresh, #863).

ACCOUNT_NS=devzone-system
ACCOUNT_SA=devzone-agent
ACCOUNT_CONFIG="${DEVZONE_KUBE_CONFIG:-$HOME/.kube/config}"

# kubeconfig file that holds the admin context ctx: hote.config if it lists it
# (host clusters), otherwise ~/.kube/config (kind clusters of the container).
account_admin_config() {
    local ctx="$1" host="${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}"
    if [ -n "$ctx" ] && [ -f "$host" ]; then
        if KUBECONFIG="$host" kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "$ctx"; then
            echo "$host"
            return 0
        fi
    fi
    echo "$ACCOUNT_CONFIG"
}

# kubectl on the admin context: explicit kubeconfig that holds this context,
# never the combined KUBECONFIG (the admin never goes through the limited
# account). Without a known context: the one kubectl uses.
account_admin() {
    local ctx="$1" conf
    shift
    if [ -z "$ctx" ]; then
        ctx="$(kubectl config current-context 2>/dev/null || true)"
    fi
    conf="$(account_admin_config "$ctx")"
    if [ -n "$ctx" ]; then
        kubectl --kubeconfig="$conf" --context "$ctx" "$@"
    else
        kubectl --kubeconfig="$conf" "$@"
    fi
}

# helm on the admin context ctx: the charts create CRDs, ClusterRoles or
# RoleBindings, beyond the limited account's rights (edit).
# Usage: account_helm <ctx> <helm args…>
account_helm() {
    local ctx="$1" conf
    shift
    if [ -z "$ctx" ]; then
        ctx="$(kubectl config current-context 2>/dev/null || true)"
    fi
    conf="$(account_admin_config "$ctx")"
    if [ -n "$ctx" ]; then
        helm --kubeconfig "$conf" --kube-context "$ctx" "$@"
    else
        helm --kubeconfig "$conf" "$@"
    fi
}

# Admin context of an installation: the chosen services cluster (cluster_saved
# of cluster.sh), otherwise the current kubectl context.
account_context() {
    local ctx
    ctx="$(cluster_saved 2>/dev/null || true)"
    if [ -n "$ctx" ]; then
        echo "$ctx"
        return 0
    fi
    kubectl config current-context 2>/dev/null || true
}

# Allows the account in namespace ns: devzone-agent RoleBinding to the edit
# ClusterRole (read, write, secrets, NetworkPolicies — no RBAC, no quotas), set
# with the admin context after the namespace is created.
# The account is set up first if missing: devzone-system namespace and
# devzone-agent ServiceAccount, so an installation on a still blank cluster
# makes the account usable at the next token renewal.
account_allow() {
    local ctx="$1" ns="$2"
    account_admin "$ctx" create namespace "$ACCOUNT_NS" --dry-run=client -o yaml |
        account_admin "$ctx" apply -f - >/dev/null || return 1
    account_admin "$ctx" -n "$ACCOUNT_NS" create serviceaccount "$ACCOUNT_SA" \
        --dry-run=client -o yaml | account_admin "$ctx" apply -f - >/dev/null || return 1
    account_admin "$ctx" -n "$ns" create rolebinding "$ACCOUNT_SA" \
        --clusterrole=edit --serviceaccount="$ACCOUNT_NS:$ACCOUNT_SA" \
        --dry-run=client -o yaml | account_admin "$ctx" apply -f - >/dev/null || return 1
}

# Removes the account's permission in namespace ns (uninstall): RoleBinding
# deleted with the admin context.
account_remove() {
    local ctx="$1" ns="$2"
    account_admin "$ctx" -n "$ns" delete rolebinding "$ACCOUNT_SA" \
        --ignore-not-found >/dev/null || return 1
}

# Creates and labels namespace ns as administrator, then allows the account.
account_namespace() {
    local ctx="$1" ns="$2"
    account_admin "$ctx" create namespace "$ns" --dry-run=client -o yaml |
        account_admin "$ctx" apply -f - >/dev/null || return 1
    account_admin "$ctx" label namespace "$ns" "$CLUSTER_LABEL" --overwrite >/dev/null || return 1
    account_allow "$ctx" "$ns" || return 1
}

# Direct execution: the token cycle moved to the devzone command of the pod
# (#863): « kube-account.sh jeton » is renamed to « devzone account token ».
# When the file is sourced, $0 differs from BASH_SOURCE: nothing runs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ "${1:-}" != jeton ]; then
        echo "devzone : kube-account : jeton" >&2
        exit 1
    fi
    echo 'devzone : « kube-account.sh jeton » was renamed: devzone account token' >&2
    exec devzone account token
fi
