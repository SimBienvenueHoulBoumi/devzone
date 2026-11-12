#!/usr/bin/env bash
# Pourquoi : make up|shell|stop|rebuild pilote toujours le conteneur Docker,
# même après « devzone workspace migrer », qui note workspace=kubernetes dans
# .devzone.modules (#472). Ce script lit ce mode : en Kubernetes il passe la
# main à manage/workspace.sh (clone du dépôt) ou à npx devzone@<version>
# workspace (dossier créé par npx devzone) ; en Docker il rend 3 sans rien
# faire, et le Makefile garde alors sa recette d'origine.
# Portable : bash 3.2 (macOS) et Linux.
set -uo pipefail

usage() {
    echo "usage : bash manage/scripts/poste.sh up|shell|stop|rebuild <dossier>" >&2
}

# Dernière valeur workspace= de <dossier>/.devzone.modules ; absente, vide ou
# autre que kubernetes → docker.
mode_workspace() {
    local dossier="$1" valeur
    valeur="$(grep '^workspace=' "$dossier/.devzone.modules" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ "$valeur" = "kubernetes" ]; then
        echo kubernetes
    else
        echo docker
    fi
}

# Version du dossier : première ligne « version X.Y.Z » de .devzone.version ;
# illisible ou vide → latest.
version_dossier() {
    local dossier="$1" version
    version="$(sed -n 's/^version \([^[:space:]]*\)[[:space:]]*$/\1/p' "$dossier/.devzone.version" 2>/dev/null | head -1 || true)"
    if [ -z "$version" ]; then
        echo latest
    else
        echo "$version"
    fi
}

# Commande workspace du dossier : le script du clone s'il existe, sinon la CLI
# publiée de la version du dossier, exécutée depuis le dossier.
workspace_cmd() {
    local dossier="$1" version
    shift
    if [ -f "$dossier/manage/workspace.sh" ]; then
        (cd "$dossier" && bash manage/workspace.sh "$@")
    else
        version="$(version_dossier "$dossier")"
        (cd "$dossier" && npx -y "devzone@$version" workspace "$@")
    fi
}

cible="${1:-}"
dossier="${2:-}"
case "$cible" in
    up | shell | stop | rebuild) ;;
    *)
        usage
        exit 2
        ;;
esac
if [ -z "$dossier" ]; then
    usage
    exit 2
fi

# Poste Docker : le Makefile reprend sa recette actuelle (code 3).
[ "$(mode_workspace "$dossier")" = kubernetes ] || exit 3

case "$cible" in
    up) workspace_cmd "$dossier" demarrer ;;
    shell) workspace_cmd "$dossier" demarrer && workspace_cmd "$dossier" shell ;;
    stop) workspace_cmd "$dossier" arreter ;;
    rebuild)
        echo "✖ make rebuild : ce poste est en workspace Kubernetes (workspace=kubernetes dans .devzone.modules), rien à reconstruire sur la machine ; retour au poste Docker : devzone workspace revenir" >&2
        exit 1
        ;;
esac
