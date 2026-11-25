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
# Library sourced by cluster.sh; executable for the token:
#   kube-account.sh jeton   (argument kept: called by startup.sh and devzone repair)

ACCOUNT_NS=devzone-system
ACCOUNT_SA=devzone-agent
ACCOUNT_DURATION=24h
ACCOUNT_CONFIG="${DEVZONE_KUBE_CONFIG:-$HOME/.kube/config}"
ACCOUNT_TOKEN_EXPIRY="${DEVZONE_KUBE_TOKEN_EXPIRY:-$HOME/.kube/devzone-token.expiry}"

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

# Sets up the limited account with the admin context: devzone-system namespace
# and devzone-agent ServiceAccount (idempotent, resumed at startup and at each
# installation).
account_setup() {
    local ctx="$1"
    account_admin "$ctx" create namespace "$ACCOUNT_NS" --dry-run=client -o yaml |
        account_admin "$ctx" apply -f - >/dev/null || return 1
    account_admin "$ctx" -n "$ACCOUNT_NS" create serviceaccount "$ACCOUNT_SA" \
        --dry-run=client -o yaml | account_admin "$ctx" apply -f - >/dev/null || return 1
}

# Allows the account in namespace ns: devzone-agent RoleBinding to the edit
# ClusterRole (read, write, secrets, NetworkPolicies — no RBAC, no quotas), set
# with the admin context after the namespace is created.
# The account is set up first if missing: an installation on a still blank
# cluster makes the account usable at the next token renewal.
account_allow() {
    local ctx="$1" ns="$2"
    account_setup "$ctx" || return 1
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

# Catches up the existing devzone namespaces: RoleBinding set in each namespace
# labelled CLUSTER_LABEL (idempotent), for the installations prior to the
# limited account.
account_catch_up() {
    local ctx="$1" ns label="${CLUSTER_LABEL:-app.kubernetes.io/managed-by=devzone}"
    while IFS= read -r ns; do
        [ -n "$ns" ] || continue
        ns="${ns#namespace/}"
        account_admin "$ctx" -n "$ns" create rolebinding "$ACCOUNT_SA" \
            --clusterrole=edit --serviceaccount="$ACCOUNT_NS:$ACCOUNT_SA" \
            --dry-run=client -o yaml | account_admin "$ctx" apply -f - >/dev/null || return 1
    done < <(account_admin "$ctx" get namespaces -l "$label" -o name 2>/dev/null || true)
}

# Epoch seconds of the RFC 3339 expiration timestamp of a TokenRequest
# response; empty when the local date cannot read it, so the caller falls back
# to now + 24 h (Bash 3.2: GNU date -d, then the BSD date form).
account_expiry_epoch() {
    local ts="$1" epoch
    [ -n "$ts" ] || return 0
    epoch="$(date -u -d "$ts" +%s 2>/dev/null || true)"
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi
    epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || true)"
    [ -n "$epoch" ] && echo "$epoch"
}

# True when the token has more than one hour left, read from the expiry file
# without any cluster call: absent, unreadable, non-numeric, close or past
# expiry → false.
account_token_fresh() {
    local expiry now
    [ -f "$ACCOUNT_TOKEN_EXPIRY" ] || return 1
    expiry="$(cat "$ACCOUNT_TOKEN_EXPIRY" 2>/dev/null || true)"
    case "$expiry" in
        '' | *[!0-9]*) return 1 ;;
    esac
    now="$(date +%s)"
    [ "$expiry" -gt $((now + 3600)) ]
}

# Renews the account's token (24 h TokenRequest) and writes it into the devzone
# context of ~/.kube/config: user devzone-agent, same cluster as the admin
# context (cluster entry copied: server, certificate authority and
# tls-server-name of the host context). The expiry timestamp of the TokenRequest
# response is kept in ACCOUNT_TOKEN_EXPIRY (now + 24 h if it is unreadable), only
# once a real call through the devzone context has succeeded.
account_token() {
    local ctx="$1" conf token cluster server tls ca_data ca_file out expires expiry now answer
    local entry=()
    conf="$(account_admin_config "$ctx")"
    out="$(account_admin "$ctx" create token "$ACCOUNT_SA" -n "$ACCOUNT_NS" \
        --duration="$ACCOUNT_DURATION" \
        -o jsonpath='{.status.token}{"\n"}{.status.expirationTimestamp}')" || return 1
    token="$(printf '%s\n' "$out" | sed -n '1p')"
    expires="$(printf '%s\n' "$out" | sed -n '2p')"
    if [ -z "$token" ]; then
        echo "devzone : limited account token is empty" >&2
        return 1
    fi
    cluster="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    if [ -z "$cluster" ]; then
        echo "devzone : cluster of context $ctx not found in $conf" >&2
        return 1
    fi
    server="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}" 2>/dev/null || true)"
    if [ -z "$server" ]; then
        echo "devzone : server of cluster $cluster not found in $conf" >&2
        return 1
    fi
    ca_data="$(KUBECONFIG="$conf" kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority-data}" 2>/dev/null || true)"
    ca_file="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority}" 2>/dev/null || true)"
    entry=(--server="$server")
    if [ -n "$ca_file" ]; then
        entry+=(--certificate-authority="$ca_file" --embed-certs=true)
    fi
    tls="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.tls-server-name}" 2>/dev/null || true)"
    if [ -n "$tls" ]; then
        entry+=(--tls-server-name="$tls")
    fi
    KUBECONFIG="$ACCOUNT_CONFIG" kubectl config set-cluster "$cluster" \
        ${entry[@]+"${entry[@]}"} >/dev/null || return 1
    if [ -n "$ca_data" ]; then
        KUBECONFIG="$ACCOUNT_CONFIG" kubectl config set \
            "clusters.$cluster.certificate-authority-data" "$ca_data" >/dev/null || return 1
    fi
    KUBECONFIG="$ACCOUNT_CONFIG" kubectl config set-credentials "$ACCOUNT_SA" \
        --token="$token" >/dev/null || return 1
    KUBECONFIG="$ACCOUNT_CONFIG" kubectl config set-context devzone \
        --cluster="$cluster" --user="$ACCOUNT_SA" >/dev/null || return 1
    answer="$(KUBECONFIG="$ACCOUNT_CONFIG" kubectl --context devzone \
        auth can-i get pods -n "$ACCOUNT_NS" 2>/dev/null || true)"
    case "$answer" in
        yes | no) ;;
        *)
            echo "devzone : limited account context not reachable" >&2
            rm -f "$ACCOUNT_TOKEN_EXPIRY"
            return 1
            ;;
    esac
    now="$(date +%s)"
    expiry="$(account_expiry_epoch "$expires")"
    [ -n "$expiry" ] || expiry=$((now + 86400))
    mkdir -p "$(dirname "$ACCOUNT_TOKEN_EXPIRY")"
    printf '%s\n' "$expiry" >"$ACCOUNT_TOKEN_EXPIRY"
    chmod 600 "$ACCOUNT_TOKEN_EXPIRY"
}

# Writes the limited agent kubeconfig: the devzone context only, current context
# set to it, for the agents that hold the limited account (Claude Code, #844).
# The contexts are read from ACCOUNT_CONFIG, never from the file being written:
# the view goes to a temporary file of the same folder, moved in place (atomic,
# mode 600); a failure empties the target and returns 1.
account_agent_config() {
    local conf="${DEVZONE_KUBE_AGENT_CONFIG:-$HOME/.kube/agent.config}" tmp
    tmp="$(mktemp "$(dirname "$conf")/.agent.config.XXXXXX")" || return 1
    # shellcheck disable=SC2015 # the failure branch must empty the target too
    ( umask 077; KUBECONFIG="$ACCOUNT_CONFIG" kubectl config view --minify --flatten \
        --context devzone >"$tmp" ) && KUBECONFIG="$tmp" kubectl config use-context devzone >/dev/null 2>&1 \
        || { rm -f "$tmp"; : >"$conf"; return 1; }
    chmod 600 "$tmp"; mv "$tmp" "$conf"
}

# Direct execution: account token renewed at startup (startup.sh) and by
# « devzone repair ». Without a chosen services cluster: nothing to do.
# When the file is sourced, $0 differs from BASH_SOURCE: nothing runs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ "${1:-}" != jeton ]; then
        echo "devzone : kube-account : jeton" >&2
        exit 1
    fi
    ICI="$(cd "$(dirname "$0")" && pwd)"
    RACINE="${DEVZONE_ROOT:-$(dirname "$ICI")}"
    ETAT="${DEVZONE_STATE:-$RACINE/.devzone.modules}"
    ctx="$(grep -E '^cluster=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ -z "$ctx" ]; then
        exit 0
    fi
    account_setup "$ctx" || exit 1
    account_catch_up "$ctx" || exit 1
    account_token "$ctx" || exit 1
    account_agent_config || exit 1
fi
