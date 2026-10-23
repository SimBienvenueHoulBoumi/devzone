#!/usr/bin/env bash
# Versions figées du conteneur : compare repowarden (post-create.sh) et les
# assistants IA (IA_PAQUETS, devzone) à la dernière version npm, ou applique
# une montée.
#   bash core/scripts/versions.sh
#       une ligne « paquet ancienne nouvelle » par paquet en retard, rien sinon
#   bash core/scripts/versions.sh --appliquer <paquet> <version>
#       remplace cette version figée dans son fichier, rien d'autre
# Compatible bash 3.2 (macOS).
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_CREATE="$ICI/.devcontainer/post-create.sh"
DEVZONE="$ICI/.devcontainer/devzone"

# Liste « paquet version » des versions figées dans les deux fichiers
figees() {
    local ligne element
    ligne="$(sed -nE 's/.*npm install -g (repowarden)@([^[:space:]]+).*/\1 \2/p' "$POST_CREATE" | head -1)"
    [ -z "$ligne" ] || echo "$ligne"
    ligne="$(sed -nE 's/^IA_PAQUETS=\((.*)\)/\1/p' "$DEVZONE" | head -1)"
    [ -n "$ligne" ] || return 0
    for element in $ligne; do
        case "$element" in
            *@*) echo "${element%@*} ${element##*@}" ;;
        esac
    done
}

# Vrai si la version $1 est plus récente que $2 (composants numériques)
plus_recente() {
    local i x y
    local IFS=.
    local a b
    read -ra a <<<"$1"
    read -ra b <<<"$2"
    for i in 0 1 2 3; do
        x="${a[i]:-0}"
        y="${b[i]:-0}"
        x="${x%%[!0-9]*}"
        y="${y%%[!0-9]*}"
        x="${x:-0}"
        y="${y:-0}"
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

# Dernière version publiée sur npm (vide si npm ne répond pas)
derniere() {
    npm view "$1" version 2>/dev/null | tail -1 | tr -d '[:space:]'
}

# Une ligne par paquet en retard, rien si tout est à jour
lister() {
    local paquet ancienne nouvelle
    while read -r paquet ancienne; do
        [ -n "$paquet" ] || continue
        nouvelle="$(derniere "$paquet")"
        if [ -z "$nouvelle" ]; then
            echo "versions : version npm illisible pour $paquet" >&2
            exit 1
        fi
        if plus_recente "$nouvelle" "$ancienne"; then
            echo "$paquet $ancienne $nouvelle"
        fi
    done < <(figees)
}

# Échappe $1 pour un motif sed (le délimiteur est « | »)
echapper() {
    printf '%s' "$1" | sed "s/[][\\\\.*^$()+?{}|]/\\\\&/g"
}

# Remplace la seule version figée de $1 par $2, dans son fichier. Le contenu
# est réécrit dans le fichier existant (pas de mv) : ses droits, notamment le
# droit d'exécution de devzone, sont conservés.
appliquer() {
    local paquet="$1" version="$2" motif tmp fichier
    case "$version" in
        "" | *[!0-9A-Za-z.+-]*)
            echo "versions : version invalide : ${version:-(aucune)}" >&2
            exit 1
            ;;
    esac
    if [ "$paquet" = repowarden ]; then
        fichier="$POST_CREATE"
        grep -qF 'npm install -g repowarden@' "$fichier" ||
            { echo "versions : paquet inconnu : $paquet" >&2; exit 1; }
        tmp="$(mktemp)"
        sed -E "s|(npm install -g repowarden@)[^[:space:]]+|\1${version}|" "$fichier" >"$tmp"
    else
        fichier="$DEVZONE"
        figees | awk -v p="$paquet" '$1 == p { trouve = 1 } END { exit trouve ? 0 : 1 }' ||
            { echo "versions : paquet inconnu : $paquet" >&2; exit 1; }
        motif="$(echapper "$paquet")"
        tmp="$(mktemp)"
        sed -E "s|(${motif}@)[^ )]+|\1${version}|" "$fichier" >"$tmp"
    fi
    cat "$tmp" >"$fichier"
    rm -f "$tmp"
}

case "${1:-}" in
    "") lister ;;
    --appliquer)
        [ "$#" -eq 3 ] ||
            { echo "usage : bash core/scripts/versions.sh [--appliquer <paquet> <version>]" >&2; exit 2; }
        appliquer "$2" "$3"
        ;;
    -h | --help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)
        echo "usage : bash core/scripts/versions.sh [--appliquer <paquet> <version>]" >&2
        exit 2
        ;;
esac
