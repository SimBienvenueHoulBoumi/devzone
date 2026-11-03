#!/usr/bin/env bash
# Clusters joignables depuis le conteneur (#291). Avec le Docker de l'hôte,
# l'API d'un cluster kind écoute sur 127.0.0.1 DU POSTE : dans le conteneur,
# 127.0.0.1 est le conteneur lui-même. On réécrit donc l'adresse vers
# host.docker.internal, en gardant le nom d'origine pour la vérification TLS
# (--tls-server-name) : le certificat de kind reste valide, sans rien exposer
# de plus sur le poste.
# Bibliothèque sourcée (cluster.sh, enveloppe kind) ; exécutée directement :
#   kube-joignable.sh FICHIER
#   kube_joignable_depuis_conteneur FICHIER   réécrit 127.0.0.1/localhost, idempotent

kube_joignable_depuis_conteneur() {
    local fichier="${1:-}" nom serveur hote
    [ -n "$fichier" ] || return 0
    KUBECONFIG="$fichier" kubectl config view \
        -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.server}{"\n"}{end}' 2>/dev/null |
        while IFS=$'\t' read -r nom serveur; do
            case "$serveur" in
                https://127.0.0.1:* | https://localhost:*) ;;
                *) continue ;;
            esac
            hote="${serveur#https://}"
            hote="${hote%%:*}"
            KUBECONFIG="$fichier" kubectl config set-cluster "$nom" \
                --server="https://host.docker.internal:${serveur##*:}" \
                --tls-server-name="$hote" >/dev/null 2>&1 || true
        done
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    kube_joignable_depuis_conteneur "${1:-}"
fi
