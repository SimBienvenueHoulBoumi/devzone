#!/usr/bin/env bash
# Isolement network et autorisation d'acces entre namespaces devzone.
# Fichier <= 250 lignes : fonctions namespace_isoler, autoriser, interdire.
# Ces fonctions modifient des NetworkPolicies dans le cluster Kubernetes.
# Aides de manage/test/commun.bash : relais_docker_isole, kube_isole.

# Pose une NetworkPolicy isolante dans un namespace.
# Seuls les pods du meme namespace peuvent joindre les services.
namespace_isoler() {
    local ns="${1:-}"
    [ -n "$ns" ] || { echo "devzone : namespace manquant" >&2; return 2; }

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

# Ajoute une règle namespaceSelector dans la NetworkPolicy du namespace cible,
# permettant l'accès depuis l'extérieur de ce namespace.
# Sans cette règle, une application dans un autre namespace ne peut pas
# joindre les services devzone (postgres, etc.).
autoriser() {
    local ns_cible="${1:-}" patch sortie
    [ -n "$ns_cible" ] || { echo "devzone : namespace cible manquant" >&2; return 2; }

    kubectl --context devzone -n "$ns_cible" get networkpolicy devzone-meme-namespace \
        -o yaml 2>/dev/null | kubectl --context devzone -n "$ns_cible" apply -f - >/dev/null 2>&1 ||
        { echo "devzone : impossible d'appliquer la NetworkPolicy isolante dans $ns_cible" >&2; return 1; }

    patch="$(jq -nc '{"spec":{"ingress":[{"from":[{"podSelector":{},
        "namespaceSelector":{"matchLabels":{"app.kubernetes.io/managed-by":"devzone"}}}]}]}}')"
    if ! sortie="$(kubectl --context devzone -n "$ns_cible" patch networkpolicy devzone-meme-namespace \
        -p "$patch" 2>&1)"; then
        echo "devzone : impossible d'autoriser l'accès vers $ns_cible : $sortie" >&2
        return 1
    fi

    echo "devzone : règle autorisée vers $ns_cible"
}

# Retire la règle namespaceSelector de la NetworkPolicy,
# bloquant à nouveau l'accès depuis le namespace specifie.
interdire() {
    local ns_cible="${1:-}" patch sortie
    [ -n "$ns_cible" ] || { echo "devzone : namespace cible manquant" >&2; return 2; }

    patch="$(jq -nc '{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}')"
    if ! sortie="$(kubectl --context devzone -n "$ns_cible" patch networkpolicy devzone-meme-namespace \
        -p "$patch" 2>&1)"; then
        echo "devzone : impossible d'interdire l'accès vers $ns_cible : $sortie" >&2
        return 1
    fi

    echo "devzone : règle interdite vers $ns_cible"
}