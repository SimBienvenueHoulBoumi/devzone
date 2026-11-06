#!/usr/bin/env bash
# Invite Kubernetes du shell (#337) : ⎈ ctx/ns.

# Rend l invite Kubernetes (⎈ ctx/ns) avec cache par mtime.
devzone_invite_kube() {
    local kubeconfig="${KUBECONFIG:-$HOME/.kube/config:$HOME/.kube/hote.config}"
    local files=() f sig="" cache mtime ctx ns result ici
    ici="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
        # shellcheck disable=SC1090,SC1091
        if ( . "$ici/cluster.sh"; cluster_est_local "$ctx" ) >/dev/null 2>&1; then
            result="$(printf '\001\033[36m\002⎈ %s/%s\001\033[0m\002' "$ctx" "$ns")"
        else
            result="$(printf '\001\033[1;31m\002⎈ %s/%s distant\001\033[0m\002' "$ctx" "$ns")"
        fi
    fi
    printf '%s\n%s\n' "$sig" "$result" >"$cache"
    printf '%s\n' "$result"
}
