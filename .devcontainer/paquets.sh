#!/usr/bin/env bash
# Paquets système gardés après un rebuild (#351) : une liste dans le dossier
# devzone (<racine>/.devzone.paquets, entête de commentaire + un nom de paquet
# par ligne, triés, sans doublon), réinstallée à chaque création du conteneur
# (post-create.sh). Un paquet installé à la main est perdu par un rebuild, sauf
# s'il est dans cette liste.
#   paquets.sh ou paquets.sh lister      liste avec l'état de chaque paquet
#   paquets.sh ajouter <nom>…            valide, installe, ajoute à la liste
#   paquets.sh retirer <nom>…            retire la liste et désinstalle
#   paquets.sh appliquer                 installe tout ce qui manque (post-create.sh)
# L'état d'un paquet vient de dpkg-query -W -f='${Status}' ; les commandes
# système passent par des variables surchargeables pour les tests (sudo, apt-get,
# apt-cache, dpkg-query, marque, horodatage). Compatible bash 3.2 (macOS).
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"
LISTE="${RACINE}/.devzone.paquets"
MARQUE="${DEVZONE_PAQUETS_MARQUE:-/tmp/devzone-paquets.echec}"
MAJ="${DEVZONE_PAQUETS_MAJ:-/tmp/devzone-paquets.maj}"
SUDO="${DEVZONE_PAQUETS_SUDO-sudo}"
APT="${DEVZONE_PAQUETS_APT:-apt-get}"
APTCACHE="${DEVZONE_PAQUETS_APTCACHE:-apt-cache}"
DPKGQUERY="${DEVZONE_PAQUETS_DPKG_QUERY:-dpkg-query}"
FORMAT="-f=\${Status}"
ENTETE="# paquets ajoutés par devzone paquets ; réinstallés à chaque création du conteneur"

refuse() { echo "devzone : paquets : $*" >&2; exit 1; }

en_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
    else
        env "$@"
    fi
}

installe() {
    "$DPKGQUERY" -W "$FORMAT" "$1" 2>/dev/null | grep -q 'install ok installed'
}

noms_liste() {
    [ -f "$LISTE" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$LISTE" 2>/dev/null |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' |
        sort -u || true
}

maj_index() {
    local dernier
    dernier="$(cat "$MAJ" 2>/dev/null || true)"
    if [ -n "$dernier" ] && [ $(( $(date +%s) - dernier )) -lt 3600 ]; then
        return 0
    fi
    en_root "$APT" update || return 1
    date +%s >"$MAJ"
}

lister() {
    local paquets paquet
    paquets="$(noms_liste)"
    if [ -z "$paquets" ]; then
        echo "aucun paquet (devzone paquets ajouter <nom>)"
        return 0
    fi
    while IFS= read -r paquet; do
        [ -n "$paquet" ] || continue
        if installe "$paquet"; then
            echo "  ✔ $paquet"
        else
            echo "  ○ $paquet"
        fi
    done < <(printf '%s\n' "$paquets")
}

ajouter() {
    local -a a=()
    local arg nom tmp
    for arg in "$@"; do
        case "$arg" in
            -*) refuse "argument inconnu : $arg (devzone paquets ajouter <nom>…)" ;;
            *) a+=("$arg") ;;
        esac
    done
    [ "${#a[@]}" -gt 0 ] || refuse "ajouter attend au moins un nom : devzone paquets ajouter <nom>…"
    for nom in "${a[@]}"; do
        if ! "$APTCACHE" show "$nom" >/dev/null 2>&1; then
            refuse "paquet inconnu : $nom (liste inchangée)"
        fi
    done
    maj_index
    if en_root DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "${a[@]}"; then
        tmp="$(mktemp)"
        echo "$ENTETE" >"$tmp"
        {
            grep -vE '^[[:space:]]*(#|$)' "$LISTE" 2>/dev/null || true
            printf '%s\n' "${a[@]}"
        } | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' | sort -u >>"$tmp"
        mv "$tmp" "$LISTE"
    else
        refuse "installation impossible : ${a[*]} (liste inchangée)"
    fi
}

retirer() {
    local -a a=()
    local -a pats=()
    local arg nom n tmp
    for arg in "$@"; do
        case "$arg" in
            -*) refuse "argument inconnu : $arg (devzone paquets retirer <nom>…)" ;;
            *) a+=("$arg") ;;
        esac
    done
    [ "${#a[@]}" -gt 0 ] || refuse "retirer attend au moins un nom : devzone paquets retirer <nom>…"
    for nom in "${a[@]}"; do
        grep -q -x -F -e "$nom" "$LISTE" 2>/dev/null ||
            refuse "paquet non listé : $nom (fourni par l'image ?) : devzone paquets retirer n'ajoute pas les paquets de l'image"
    done
    if en_root "$APT" remove -y "${a[@]}"; then
        tmp="$(mktemp)"
        echo "$ENTETE" >"$tmp"
        for n in "${a[@]}"; do
            pats+=(-e "$n")
        done
        grep -v -x -F "${pats[@]}" "$LISTE" >>"$tmp" || true
        mv "$tmp" "$LISTE"
    else
        refuse "désinstallation impossible : ${a[*]}"
    fi
}

appliquer() {
    local paquet
    local -a manquants=()
    while IFS= read -r paquet; do
        [ -n "$paquet" ] || continue
        if ! installe "$paquet"; then
            manquants+=("$paquet")
        fi
    done < <(printf '%s\n' "$(noms_liste)")
    if [ "${#manquants[@]}" -eq 0 ]; then
        rm -f "$MARQUE"
        return 0
    fi
    if en_root DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "${manquants[@]}"; then
        :
    fi
    local -a restants=()
    for paquet in "${manquants[@]}"; do
        if ! installe "$paquet"; then
            restants+=("$paquet")
        fi
    done
    if [ "${#restants[@]}" -gt 0 ]; then
        printf '%s\n' "${restants[@]}" >"$MARQUE"
        return 1
    fi
    rm -f "$MARQUE"
}

case "${1:-}" in
    '' | lister) lister ;;
    ajouter) ajouter "${@:2}" ;;
    retirer) retirer "${@:2}" ;;
    appliquer) appliquer ;;
    -h | --help | aide) awk 'NR==1{next} /^#$/{exit} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}" ;;
    *) refuse "commande inconnue : ${1:-(aucune)} (devzone paquets --help)" ;;
esac
