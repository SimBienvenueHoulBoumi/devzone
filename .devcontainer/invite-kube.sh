#!/usr/bin/env bash
# Invite Kubernetes du shell (#337) : ⎈ ctx/ns.
ICI="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F cluster_est_local >/dev/null 2>&1; then
    if [ -f "$ICI/cluster.sh" ]; then
        # shellcheck source=SCRIPTDIR/cluster.sh
        # shellcheck disable=SC1091
        # shellcheck disable=SC1091
        . "$ICI/cluster.sh"
    fi
fi

devzone_invite_kube() {
    local kubeconfig="${KUBECONFIG:-$HOME/.kube/config:$HOME/.kube/hote.config}"
    local files=() f sig="" cache mtime ctx ns result
    IFS=':' read -ra files <<<"$kubeconfig"
    for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        if [ -f "$f" ]; then
            mtime="$(stat -c '%Y' "$f" 2>/dev/null || echo 0)"
        else
            mtime="missing"
        fi
        sig+="${f}:${mtime};"
    done
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/devzone-invite-kube"
    mkdir -p "$(dirname "$cache")"
    if [ -f "$cache" ]; then
        if [ "$(sed -n '1p' "$cache" 2>/dev/null)" = "$sig" ]; then
            sed -n '2p' "$cache" 2>/dev/null
            return 0
        fi
    fi
    ctx="$(kubectl config current-context 2>/dev/null || true)"
    if [ -z "$ctx" ]; then
        result=""
    else
        ns="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.namespace}" 2>/dev/null || true)"
        [ -n "$ns" ] || ns=default
        if cluster_est_local "$ctx" >/dev/null 2>&1; then
            result="$(printf '\033[36m⎈ %s/%s\033[0m' "$ctx" "$ns")"
        else
            result="$(printf '\033[1;31m⎈ %s/%s distant\033[0m' "$ctx" "$ns")"
        fi
    fi
    printf '%s\n%s\n' "$sig" "$result" >"$cache"
    printf '%s\n' "$result"
}
