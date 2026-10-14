#!/usr/bin/env bash
# Config kubectl du conteneur, refaite à chaque démarrage (le port du cluster
# Docker Desktop peut changer) : copie de ~/.kube du Mac (monté en lecture seule)
# où 127.0.0.1/localhost deviennent host.docker.internal, l'adresse du Mac vue
# du conteneur. tls-server-name garde le nom attendu par le certificat.
set -euo pipefail

SOURCE="$HOME/.kube-host/config"
CIBLE="$HOME/.kube/config"

if [ ! -f "$SOURCE" ]; then
    echo "kube-config : pas de $SOURCE, kubectl sans cluster"
    exit 0
fi

mkdir -p "$(dirname "$CIBLE")"
install -m 600 "$SOURCE" "$CIBLE"

export KUBECONFIG="$CIBLE"
kubectl config view -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.server}{"\n"}{end}' |
    while IFS=$'\t' read -r nom serveur; do
        case "$serveur" in
            https://127.0.0.1:* | https://localhost:*) ;;
            *) continue ;;
        esac
        hote="${serveur#https://}"
        hote="${hote%%:*}"
        kubectl config set-cluster "$nom" \
            --server="https://host.docker.internal:${serveur##*:}" \
            --tls-server-name="$hote" >/dev/null
        echo "kube-config : $nom → host.docker.internal:${serveur##*:}"
    done
