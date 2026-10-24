#!/usr/bin/env bash
# Versions figées du conteneur : compare repowarden (post-create.sh) et les
# assistants IA (lignes IA_…, devzone) à la dernière version npm, ou applique
# une montée.
#   bash core/scripts/versions.sh
#       une ligne « paquet ancienne nouvelle » par paquet en retard, rien sinon
#   bash core/scripts/versions.sh --installees
#       une ligne « paquet figée installée » par outil installé en retard
#   bash core/scripts/versions.sh --appliquer <paquet> <version>
#       remplace cette version figée dans son fichier, rien d'autre
#   bash core/scripts/versions.sh --ticket-existant <paquet> <auteur>
#       « numéro<TAB>titre » du ticket ouvert par <auteur>, rien sinon
# Compatible bash 3.2 (macOS).
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_CREATE="$ICI/.devcontainer/post-create.sh"
DEVZONE="$ICI/.devcontainer/devzone"

# Liste « paquet version » des versions figées dans les deux fichiers ; dans
# devzone, une ligne IA_<NOM>=<paquet>@<version> par assistant IA
figees() {
    local ligne element
    ligne="$(sed -nE 's/.*npm install -g (repowarden)@([^[:space:]]+).*/\1 \2/p' "$POST_CREATE" | head -1)"
    [ -z "$ligne" ] || echo "$ligne"
    while read -r element; do
        case "$element" in
            ?*@*) echo "${element%@*} ${element##*@}" ;;
        esac
    done < <(sed -nE 's/^IA_[A-Z0-9_]+=([^[:space:]()"]+)$/\1/p' "$DEVZONE")
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

# Versions installées globalement (paquet version), lues en une seule fois ;
# échoue si npm ou jq ne répond pas (l'état omet alors la ligne)
installees() {
    local json
    json="$(npm ls -g --depth=0 --json 2>/dev/null || true)"
    [ -n "$json" ] || return 1
    printf '%s\n' "$json" | jq -r '.dependencies // {} | to_entries[] | "\(.key) \(.value.version)"'
}

# Une ligne « paquet figée installée » par outil installé dont la version
# diffère de la version figée ; un outil non installé n'est pas listé
comparer_installees() {
    local paquet figee installee liste
    liste="$(installees)"
    while read -r paquet figee; do
        [ -n "$paquet" ] || continue
        installee="$(printf '%s\n' "$liste" | awk -v p="$paquet" '$1 == p { print $2; exit }')"
        [ -n "$installee" ] || continue
        [ "$installee" = "$figee" ] || echo "$paquet $figee $installee"
    done < <(figees)
}

# Affiche « numéro<TAB>titre » du ticket ouvert par $2 dont le titre commence
# par « $1 », rien sinon : un ticket au même titre ouvert par un autre est ignoré.
ticket_existant() {
    local paquet="$1" auteur="$2" tickets numero titre auteur_ticket
    tickets="$(gh issue list --state open --limit 200 --json number,title,author \
        --jq '.[] | "\(.number)\t\(.title)\t\(.author.login)"')"
    while IFS=$'\t' read -r numero titre auteur_ticket; do
        [ -n "$numero" ] || continue
        case "$titre" in
            "$paquet "*) ;;
            *) continue ;;
        esac
        [ "$auteur_ticket" = "$auteur" ] || continue
        printf '%s\t%s\n' "$numero" "$titre"
        return 0
    done <<<"$tickets"
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
        sed -E "s|^(IA_[A-Z0-9_]+=${motif}@)[^[:space:]]+$|\1${version}|" "$fichier" >"$tmp"
    fi
    cat "$tmp" >"$fichier"
    rm -f "$tmp"
}

case "${1:-}" in
    "") lister ;;
    --installees) comparer_installees ;;
    --appliquer)
        [ "$#" -eq 3 ] ||
            { echo "usage : bash core/scripts/versions.sh [--installees | --appliquer <paquet> <version> | --ticket-existant <paquet> <auteur>]" >&2; exit 2; }
        appliquer "$2" "$3"
        ;;
    --ticket-existant)
        [ "$#" -eq 3 ] ||
            { echo "usage : bash core/scripts/versions.sh [--installees | --appliquer <paquet> <version> | --ticket-existant <paquet> <auteur>]" >&2; exit 2; }
        ticket_existant "$2" "$3"
        ;;
    -h | --help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)
        echo "usage : bash core/scripts/versions.sh [--installees | --appliquer <paquet> <version> | --ticket-existant <paquet> <auteur>]" >&2
        exit 2
        ;;
esac
