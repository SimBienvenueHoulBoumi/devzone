#!/usr/bin/env bash
# Clusters joignables depuis le conteneur (#291). Avec le Docker de l'hôte,
# l'API d'un cluster kind écoute sur 127.0.0.1 DU POSTE : dans le conteneur,
# 127.0.0.1 est le conteneur lui-même.
# 1. Nœud kind trouvé (conteneur qui publie ce port) : le conteneur devzone
#    rejoint le réseau Docker du nœud et vise https://<nœud>:6443, l'adresse
#    que kind prévoit pour les conteneurs (kind get kubeconfig --internal) ;
#    le nom du nœud est dans le certificat de l'API. Marche sous Linux comme
#    avec Docker Desktop, sans rien exposer sur le réseau du poste.
# 2. Sinon : https://host.docker.internal:<port>, avec le nom d'origine pour
#    la vérification TLS (--tls-server-name) ; suffit avec Docker Desktop, où
#    host.docker.internal mène au 127.0.0.1 du poste.
# Bibliothèque sourcée (cluster.sh, enveloppe kind) ; exécutée directement :
#   kube-joignable.sh FICHIER
#   kube_joignable_depuis_conteneur FICHIER   réécrit 127.0.0.1/localhost, idempotent

# Nœud kind de plan de contrôle qui publie ce port sur le poste (vide sinon)
kube_noeud_kind() {
    docker ps --filter "label=io.x-k8s.kind.role=control-plane" --filter "publish=$1" \
        --format '{{.Names}}' 2>/dev/null | head -1
}

# Le conteneur devzone rejoint le réseau du nœud (idempotent : déjà membre = rien)
kube_rejoindre_reseau() {
    local noeud="$1" moi reseau
    moi="$(hostname)"
    for reseau in $(docker inspect "$noeud" \
        --format '{{range $nom, $v := .NetworkSettings.Networks}}{{$nom}} {{end}}' 2>/dev/null); do
        docker network connect "$reseau" "$moi" >/dev/null 2>&1 || true
    done
}

kube_joignable_depuis_conteneur() {
    local fichier="${1:-}" nom serveur hote port noeud
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
            port="${serveur##*:}"
            noeud="$(kube_noeud_kind "$port")"
            if [ -n "$noeud" ]; then
                kube_rejoindre_reseau "$noeud"
                KUBECONFIG="$fichier" kubectl config set-cluster "$nom" \
                    --server="https://${noeud}:6443" >/dev/null 2>&1 || true
            else
                KUBECONFIG="$fichier" kubectl config set-cluster "$nom" \
                    --server="https://host.docker.internal:${port}" \
                    --tls-server-name="$hote" >/dev/null 2>&1 || true
            fi
        done
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    kube_joignable_depuis_conteneur "${1:-}"
fi
