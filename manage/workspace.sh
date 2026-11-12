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

# Dépôt de l'image publiée à chaque livraison de devzone.
IMAGE_DEPOT="ghcr.io/simbienvenuehoulboumi/devzone-workspace"

# Pourquoi : sans tag, le chart prend son appVersion (0.1.0), une image jamais
# publiée ; la version du paquet est publiée à chaque livraison, et un clone de
# développement (0.0.0) utilise latest.
image_par_defaut() {
    local version
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$RACINE/package.json" | head -1)"
    if [ -z "$version" ] || [ "$version" = "0.0.0" ]; then
        echo "latest"
    else
        echo "$version"
    fi
}

# Installe ou met à jour le workspace dans le cluster.
demarrer() {
    local depot tag image avec_image="" args=()
    depot="$IMAGE_DEPOT"
    tag="$(image_par_defaut)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --image)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    echo "✖ option --image : indique une image <repository:tag> (devzone workspace demarrer --image <repository:tag>)" >&2
                    return 1
                fi
                case "$2" in
                    *:*)
                        depot="${2%:*}"
                        tag="${2##*:}"
                        avec_image=oui
                        ;;
                    *)
                        echo "✖ option --image : image sans tag, attendu <repository:tag> (devzone workspace demarrer --image <repository:tag>)" >&2
                        return 1
                        ;;
                esac
                shift 2
                ;;
            *)
                echo "✖ option inconnue : $1 (devzone workspace demarrer [--image <repository:tag>])" >&2
                return 1
                ;;
        esac
    done
    image="$depot:$tag"
    # Argo CD first when wanted (#516): the workspace is then an Application
    argocd_ensure
    workspace_deploy "$depot" "$tag" "$avec_image"
    # Projects of .argocd.conf held too (#516)
    argocd_reconcile || true
    attendre_pod "$image" || return 1
    ports_demarrer silence
}

# helm direct: the chart of the package, image set by the options
workspace_helm_deploy() {
    local depot="$1" tag="$2" avec_image="$3" args=()
    args=(--namespace devzone-workspace --create-namespace)
    if [ -n "$avec_image" ]; then
        args+=(--set "image.repository=$depot" --set "image.tag=$tag")
    else
        args+=(--set "image.tag=$tag")
    fi
    # latest moves at every release: an image already on the node would stay
    # the old one with IfNotPresent (#515)
    if [ "$tag" = latest ]; then
        args+=(--set "image.pullPolicy=Always")
    fi
    # shellcheck disable=SC2046
    helm $(drapeau_helm) upgrade --install devzone-workspace "$(chemin_chart)" "${args[@]}"
}

# Désinstalle le workspace du cluster (Application Argo CD ou release helm).
arreter() {
    ports_arreter
    workspace_undeploy
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

# shellcheck source=scripts/workspace-wait.sh
. "$ICI/scripts/workspace-wait.sh"
# shellcheck source=scripts/migrer.sh
. "$ICI/scripts/migrer.sh"
# shellcheck source=scripts/migrer-retour.sh
. "$ICI/scripts/migrer-retour.sh"
# shellcheck source=scripts/ports-workspace.sh
. "$ICI/scripts/ports-workspace.sh"
# shellcheck source=scripts/services-workspace.sh
. "$ICI/scripts/services-workspace.sh"
# shellcheck source=scripts/argocd-workspace.sh
. "$ICI/scripts/argocd-workspace.sh"
# shellcheck source=scripts/argocd-services.sh
. "$ICI/scripts/argocd-services.sh"

# English command names are accepted, French ones unchanged (#502).
# A copied devzone may miss the aliases file: then no normalization.
# shellcheck source=../.devcontainer/command-aliases.sh
# shellcheck disable=SC1091
if [ -f "$RACINE/.devcontainer/command-aliases.sh" ]; then
    . "$RACINE/.devcontainer/command-aliases.sh"
    if [ "$#" -gt 0 ]; then
        set -- "$(command_canonical "$1")" "${@:2}"
    fi
fi

case "${1:-}" in
    demarrer) demarrer "${@:2}" ;;
    arreter) arreter ;;
    etat) etat ;;
    shell) shell ;;
    vscode) vscode ;;
    copier-vers) copier_vers "${@:2}" ;;
    copier-depuis) copier_depuis "${@:2}" ;;
    ports) ports "${@:2}" ;;
    migrer) migrer "${@:2}" ;;
    revenir) revenir "${@:2}" ;;
    nettoyer-docker) nettoyer_docker "${@:2}" ;;
    services) services "${@:2}" ;;
    argocd) argocd_cmd "${@:2}" ;;
    '' | -h | --help | aide)
        echo "devzone workspace demarrer|arreter|etat|shell|vscode|copier-vers|copier-depuis|ports|services|argocd|migrer|revenir|nettoyer-docker"
        echo "  demarrer [--image dépôt:tag]  installe le workspace (image de la version de devzone par défaut)"
        echo "  ports [demarrer|arreter|etat] applications et services du pod sur localhost du poste"
        echo "  services enable|disable <service> [options] | status"
        echo "                        devzone services (gitlab, postgres, argocd) of the cluster, installed from the workstation"
        echo "  argocd status | app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>"
        echo "                        Argo CD of the workspace: deployments held in Git, your projects as Applications"
        echo "  migrer [--oui]        copie le poste Docker vers le workspace Kubernetes (rien n'est supprimé)"
        echo "  revenir [--rapatrier] retour au poste Docker ; --rapatrier : projets du pod recopiés d'abord"
        echo "  nettoyer-docker       supprime les volumes Docker devzone-*, après confirmation [o/N] (--oui)"
        ;;
    *)
        echo "✖ sous-commande inconnue : $1 (devzone workspace demarrer|arreter|etat|shell|vscode|copier-vers|copier-depuis|ports|services|argocd|migrer|revenir|nettoyer-docker)" >&2
        exit 1
        ;;
esac
