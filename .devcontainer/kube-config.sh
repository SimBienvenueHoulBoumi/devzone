#!/usr/bin/env bash
# Clusters Kubernetes du conteneur, à chaque démarrage (le port du cluster de
# l'hôte peut changer) :
# - ~/.kube/hote.config : copie du ~/.kube de l'hôte (monté en lecture seule) où
#   127.0.0.1/localhost deviennent host.docker.internal, l'hôte vu du conteneur ;
#   tls-server-name garde le nom attendu par le certificat
# - ~/.kube/config : clusters kind du conteneur, jamais touché ici
# KUBECONFIG (devcontainer.json) combine les deux.
# Module kubernetes (devzone activer kubernetes) : connexion au cluster de
# l'hôte et metrics-server seulement s'il est actif ; les contextes kind sont
# toujours remis (un cluster créé à la main reste utilisable).
set -euo pipefail

ICI="$(dirname "$0")"
module=off
bash "$ICI/devzone" actif kubernetes && module=on

# DEVZONE_KUBE_SOURCE : tests fonctionnels (jamais le cluster de l'hôte)
SOURCE="${DEVZONE_KUBE_SOURCE:-$HOME/.kube-host/config}"
HOTE="$HOME/.kube/hote.config"

mkdir -p "$HOME/.kube"
rm -f "$HOTE"
# Doit exister : sinon kind écrit dans hote.config, effacé au prochain démarrage
[ -f "$HOME/.kube/config" ] || install -m 600 /dev/null "$HOME/.kube/config"

if [ "$module" = on ] && [ -f "$SOURCE" ]; then
    install -m 600 "$SOURCE" "$HOTE"
    KUBECONFIG="$HOTE" kubectl config view \
        -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.server}{"\n"}{end}' |
        while IFS=$'\t' read -r nom serveur; do
            case "$serveur" in
                https://127.0.0.1:* | https://localhost:*) ;;
                *) continue ;;
            esac
            hote="${serveur#https://}"
            hote="${hote%%:*}"
            KUBECONFIG="$HOTE" kubectl config set-cluster "$nom" \
                --server="https://host.docker.internal:${serveur##*:}" \
                --tls-server-name="$hote" >/dev/null
        done
fi

# Clusters kind qui ont survécu au redémarrage : contexte remis dans ~/.kube/config
# (le Docker interne peut mettre quelques secondes à démarrer)
for _ in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 1; done
choix="$(KUBECONFIG="$HOME/.kube/config" kubectl config current-context 2>/dev/null || true)"
for cluster in $(kind get clusters 2>/dev/null); do
    kind export kubeconfig --name "$cluster" --kubeconfig "$HOME/.kube/config" >/dev/null 2>&1 || true
done

# Cluster actif : celui choisi avant (kubectl config use-context), sinon celui
# de l'hôte s'il en a un (current-context de hote.config), sinon kind
export KUBECONFIG="$HOME/.kube/config:$HOTE"
if [ -n "$choix" ] && kubectl config use-context "$choix" >/dev/null 2>&1; then
    :
elif [ -f "$HOTE" ] && [ -n "$(KUBECONFIG="$HOTE" kubectl config current-context 2>/dev/null)" ]; then
    KUBECONFIG="$HOME/.kube/config" kubectl config unset current-context >/dev/null
fi

# Clusters joignables, parmi ceux de l'hôte et ceux de kind
joignables=0
for contexte in $(kubectl config get-contexts -o name 2>/dev/null); do
    if kubectl --context "$contexte" --request-timeout=3s get --raw /readyz >/dev/null 2>&1; then
        echo "kube-config : cluster joignable : $contexte"
        joignables=$((joignables + 1))
    elif [[ "$contexte" == kind-* ]]; then
        echo "kube-config : cluster kind en cours de démarrage : $contexte"
        joignables=$((joignables + 1))
    fi
done
if [ "$module" = off ]; then
    [ ! -f "$SOURCE" ] || echo "kube-config : cluster de l'hôte non connecté, module kubernetes désactivé : devzone activer kubernetes"
    exit 0
fi
echo "kube-config : cluster actif : $(kubectl config current-context 2>/dev/null || echo aucun)"
if [ "$joignables" -eq 0 ]; then
    echo "kube-config : aucun cluster joignable ; en créer un dans le conteneur : kind create cluster"
fi

# CPU/RAM dans k9s : metrics-server sur les clusters joignables qui ne l'ont pas
bash "$ICI/metrics-server.sh" || true
