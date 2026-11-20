#!/usr/bin/env bash
# View of the connected clusters (#337): visible contexts, type, state, namespace.
ICI="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F cluster_is_local >/dev/null 2>&1; then
    # shellcheck source=SCRIPTDIR/cluster.sh
    # shellcheck disable=SC1091
    . "$ICI/cluster.sh"
fi

# Shows the view of the connected clusters.
clusters_show() {
    local contexts=() ctx ctx_work ctx_services tmp i ns type state mark marks
    ctx_work="$(kubectl config current-context 2>/dev/null || true)"
    ctx_services="$(cluster_saved 2>/dev/null || true)"
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        contexts+=("$ctx")
    done < <(kubectl config get-contexts -o name 2>/dev/null || true)

    if [ "${#contexts[@]}" -eq 0 ]; then
        echo "no cluster: kind create cluster, or devzone enable kubernetes"
        return 0
    fi

    printf '%s %-14s %-8s %-12s %s\n' "  " "CONTEXT" "TYPE" "STATE" "NAMESPACE"
    tmp="$(mktemp -d)"
    for i in "${!contexts[@]}"; do
        ctx="${contexts[$i]}"
        (
            if kubectl --context "$ctx" --request-timeout=3s get --raw /readyz >/dev/null 2>&1; then
                echo reachable
            else
                echo unreachable
            fi
        ) >"$tmp/$i" &
    done
    wait
    for i in "${!contexts[@]}"; do
        ctx="${contexts[$i]}"
        state="$(cat "$tmp/$i" 2>/dev/null || echo unreachable)"
        if cluster_is_local "$ctx" >/dev/null 2>&1; then
            type=local
        else
            type=remote
        fi
        ns="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.namespace}" 2>/dev/null || true)"
        [ -n "$ns" ] || ns=default
        mark=""
        marks=0
        if [ "$ctx" = "$ctx_work" ]; then
            mark+="★"
            marks=$((marks + 1))
        fi
        if [ "$ctx" = "$ctx_services" ]; then
            mark+="●"
            marks=$((marks + 1))
        fi
        while [ "$marks" -lt 2 ]; do
            mark+=" "
            marks=$((marks + 1))
        done
        printf '%s %-14s %-8s %-12s %s\n' "$mark" "$ctx" "$type" "$state" "$ns"
    done
    rm -rf "$tmp"
    echo
    echo "★ working cluster (kubectl, k9s, helm) · ● devzone services cluster (devzone cluster)"
    # Display of the NetworkPolicy isolation state for the services cluster
    if [ -n "$ctx_services" ] && cluster_is_local "$ctx_services"; then
        if kubectl --context "$ctx_services" get networkpolicy devzone-meme-namespace -n devzone-postgres >/dev/null 2>&1; then
            printf '  ✔ isolated (NetworkPolicy) → %s\n' "$ctx_services"
        else
            printf '  ⚠ isolated (NetworkPolicy missing) → %s\n' "$ctx_services"
        fi
        printf '  devzone → %s\n' "$ctx_services"
    fi
    return 0
}

# Aliases of the devzone clusters command.
clusters() { clusters_show "$@"; }
# Alias for the tests and direct calls.
devzone_clusters() { clusters_show "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    clusters_show "$@"
fi
