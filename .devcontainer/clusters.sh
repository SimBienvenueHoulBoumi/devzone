#!/usr/bin/env bash
# Vue des clusters connectés (#337) : contextes visibles, type, état, namespace.
ICI="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F cluster_est_local >/dev/null 2>&1; then
    # shellcheck source=SCRIPTDIR/cluster.sh
    # shellcheck disable=SC1091
    # shellcheck disable=SC1091
    . "$ICI/cluster.sh"
fi

# Affiche la vue des clusters connectés.
clusters_afficher() {
    local contextes=() ctx ctx_travail ctx_services tmp i ns type etat marque
    ctx_travail="$(kubectl config current-context 2>/dev/null || true)"
    ctx_services="$(cluster_lu 2>/dev/null || true)"
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        contextes+=("$ctx")
    done < <(kubectl config get-contexts -o name 2>/dev/null || true)

    if [ "${#contextes[@]}" -eq 0 ]; then
        echo "aucun cluster : kind create cluster, ou devzone activer kubernetes"
        return 0
    fi

    printf '%s %-14s %-8s %-12s %s\n' "  " "CONTEXTE" "TYPE" "ÉTAT" "NAMESPACE"
    tmp="$(mktemp -d)"
    for i in "${!contextes[@]}"; do
        ctx="${contextes[$i]}"
        (
            if kubectl --context "$ctx" --request-timeout=3s get --raw /readyz >/dev/null 2>&1; then
                echo joignable
            else
                echo injoignable
            fi
        ) >"$tmp/$i" &
    done
    wait
    for i in "${!contextes[@]}"; do
        ctx="${contextes[$i]}"
        etat="$(cat "$tmp/$i" 2>/dev/null || echo injoignable)"
        if cluster_est_local "$ctx" >/dev/null 2>&1; then
            type=local
        else
            type=distant
        fi
        ns="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.namespace}" 2>/dev/null || true)"
        [ -n "$ns" ] || ns=default
        marque=""
        [ "$ctx" = "$ctx_travail" ] && marque+="★"
        [ "$ctx" = "$ctx_services" ] && marque+="●"
        while [ "${#marque}" -lt 2 ]; do marque+=" "; done
        printf '%s %-14s %-8s %-12s %s\n' "$marque" "$ctx" "$type" "$etat" "$ns"
    done
    rm -rf "$tmp"
    echo
    echo "★ cluster de travail (kubectl, k9s, helm) · ● cluster des services de devzone (devzone cluster)"
    return 0
}

# Alias de la commande devzone clusters.
clusters() { clusters_afficher "$@"; }
# Alias pour les tests et l appel direct.
devzone_clusters() { clusters_afficher "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    clusters_afficher "$@"
fi
