#!/usr/bin/env bash
# Commandes du poste pour le workspace Kubernetes (#398, #399) : pilote le chart
# charts/devzone-workspace avec helm et kubectl de l'hôte.
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="$(cd "$ICI/.." && pwd)"

# Pod, namespace et dossier des projets dans le conteneur (#399).
POD="devzone-workspace-0"
NAMESPACE="devzone-workspace"
DOSSIER_PROJETS="/workspaces/projets"

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

# Marche à suivre VS Code (#399) : attachement au pod avec les extensions
# Kubernetes et Dev Containers, sans autre commande que devzone.
vscode() {
    cat <<EOF
Attache VS Code au pod : extensions « Kubernetes » et « Dev Containers »
  1. Contexte kubectl : devzone — namespace $NAMESPACE, pod $POD, conteneur workspace
  2. Vue Kubernetes : clic droit sur le conteneur workspace,
     « Attach to Running Kubernetes Container »
     (avec l'extension Dev Containers : « Dev Containers: Attach to Running Container »)
  3. Ouvre le dossier $DOSSIER_PROJETS dans la fenêtre attachée
Pod non prêt : devzone workspace etat
EOF
}

# Copie un dossier du poste vers $DOSSIER_PROJETS du pod (#399, kubectl cp) :
# le projet reprend son nom de dossier dans le pod.
copier_vers() {
    local dossier="${1:-}"
    if [ -z "$dossier" ]; then
        echo "✖ indique un dossier du poste : devzone workspace copier-vers <dossier>" >&2
        exit 1
    fi
    if [ ! -d "$dossier" ]; then
        echo "✖ dossier introuvable : $dossier" >&2
        exit 1
    fi
    dossier="$(cd "$dossier" && pwd)"
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) cp "$dossier" "$POD:$DOSSIER_PROJETS/$(basename "$dossier")" \
        --namespace "$NAMESPACE" -c workspace
}

# Copie un projet de $DOSSIER_PROJETS du pod vers le poste (#399, kubectl cp) :
# le dossier du poste porte le nom du projet.
copier_depuis() {
    local dossier="${1:-}"
    if [ -z "$dossier" ]; then
        echo "✖ indique un dossier du poste : devzone workspace copier-depuis <dossier>" >&2
        exit 1
    fi
    # Chemin absolu : « copier-depuis . » donne le nom du dossier courant.
    dossier="$(cd "$dossier" 2>/dev/null && pwd || echo "$dossier")"
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) cp "$POD:$DOSSIER_PROJETS/$(basename "$dossier")" "$dossier" \
        --namespace "$NAMESPACE" -c workspace
}

# shellcheck source=scripts/migrer.sh
. "$ICI/scripts/migrer.sh"
# shellcheck source=scripts/migrer-retour.sh
. "$ICI/scripts/migrer-retour.sh"

case "${1:-}" in
    demarrer) demarrer ;;
    arreter) arreter ;;
    etat) etat ;;
    shell) shell ;;
    vscode) vscode ;;
    copier-vers) copier_vers "${@:2}" ;;
    copier-depuis) copier_depuis "${@:2}" ;;
    migrer) migrer "${@:2}" ;;
    revenir) revenir "${@:2}" ;;
    nettoyer-docker) nettoyer_docker "${@:2}" ;;
    '' | -h | --help | aide)
        echo "devzone workspace demarrer|arreter|etat|shell|vscode|copier-vers|copier-depuis|migrer|revenir|nettoyer-docker"
        echo "  migrer [--oui]        copie le poste Docker vers le workspace Kubernetes (rien n'est supprimé)"
        echo "  revenir [--rapatrier] retour au poste Docker ; --rapatrier : projets du pod recopiés d'abord"
        echo "  nettoyer-docker       supprime les volumes Docker devzone-*, après confirmation [o/N] (--oui)"
        ;;
    *)
        echo "✖ sous-commande inconnue : $1 (devzone workspace demarrer|arreter|etat|shell|vscode|copier-vers|copier-depuis|migrer|revenir|nettoyer-docker)" >&2
        exit 1
        ;;
esac
