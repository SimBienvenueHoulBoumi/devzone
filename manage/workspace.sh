#!/usr/bin/env bash
# Commandes du poste pour le workspace Kubernetes (#398) : pilote le chart
# charts/devzone-workspace avec helm et kubectl de l'hôte.
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="$(cd "$ICI/.." && pwd)"

# Drapeau helm : contexte devzone s'il existe, sinon le contexte courant (aucun drapeau).
drapeau_helm() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        printf -- '--kube-context devzone'
    fi
}

# Drapeau kubectl : contexte devzone s'il existe, sinon le contexte courant (aucun drapeau).
drapeau_kubectl() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        printf -- '--context devzone'
    fi
}

# Chemin du chart dans le dépôt (ou le paquet installé).
chemin_chart() {
    printf '%s/charts/devzone-workspace' "$RACINE"
}

# Installe ou met à jour le workspace dans le cluster.
demarrer() {
    # shellcheck disable=SC2046
    helm $(drapeau_helm) upgrade --install devzone-workspace "$(chemin_chart)" \
        --namespace devzone-workspace --create-namespace
}

# Désinstalle le workspace du cluster.
arreter() {
    # shellcheck disable=SC2046
    helm $(drapeau_helm) uninstall devzone-workspace --namespace devzone-workspace
}

# Affiche l'état des pods du workspace.
etat() {
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) get pods --namespace devzone-workspace
}

# Ouvre un shell dans le conteneur workspace.
shell() {
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) exec -it devzone-workspace-0 \
        --namespace devzone-workspace -c workspace -- bash
}

case "${1:-}" in
    demarrer) demarrer ;;
    arreter) arreter ;;
    etat) etat ;;
    shell) shell ;;
    '' | -h | --help | aide)
        echo "devzone workspace demarrer|arreter|etat|shell"
        ;;
    *)
        echo "✖ sous-commande inconnue : $1 (devzone workspace demarrer|arreter|etat|shell)" >&2
        exit 1
        ;;
esac
