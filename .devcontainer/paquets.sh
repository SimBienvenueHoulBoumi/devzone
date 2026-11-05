#!/usr/bin/env bash
# Paquets système gardés après un rebuild (#351) : une liste dans le dossier
# devzone (<racine>/.devzone.paquets, entête de commentaire + un nom de paquet
# par ligne, triés, sans doublon), réinstallée à chaque création du conteneur
# (post-create.sh). Un paquet installé à la main est perdu par un rebuild, sauf
# s'il est dans cette liste.
#   paquets.sh ou paquets.sh lister      liste avec l'état de chaque paquet
#   paquets.sh ajouter <nom>…            valide, installe, ajoute à la liste
#   paquets.sh retirer <nom>…            retire de la liste et désinstalle (sauf paquet de l'image)
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
PRESENT="# déjà présent"

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

# Lignes de la liste telles quelles (nom, ou nom suivi de la marque PRESENT).
lignes_liste() {
    [ -f "$LISTE" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$LISTE" 2>/dev/null |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' |
        sort -k1,1 -u || true
}

# Noms seuls : la marque de fin de ligne est ignorée.
noms_liste() {
    lignes_liste | sed -e 's/[[:space:]]*#.*$//' | sort -u || true
}

nom_listee() {
    local nom
    while IFS= read -r nom; do
        [ "$nom" = "$1" ] && return 0
    done < <(noms_liste)
    return 1
}

# Vrai si le paquet a été marqué comme déjà présent dans l'image.
marque_presente() {
    grep -qxF -e "$1 $PRESENT" "$LISTE" 2>/dev/null
}

# Réécrit la liste : un seul en-tête, puis les lignes données (triées par nom).
ecrire_liste() {
    local tmp
    tmp="$(mktemp)"
    {
        echo "$ENTETE"
        [ "$#" -eq 0 ] || printf '%s\n' "$@" | sort -k1,1 -u
    } >"$tmp"
    mv "$tmp" "$LISTE"
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
    local -a entrees=()
    local arg nom ligne deja=""
    for arg in "$@"; do
        case "$arg" in
            -*) refuse "argument inconnu : $arg (devzone paquets ajouter <nom>…)" ;;
            *) a+=("$arg") ;;
        esac
    done
    [ "${#a[@]}" -gt 0 ] || refuse "ajouter attend au moins un nom : devzone paquets ajouter <nom>…"
    maj_index || echo "index apt non mis à jour" >&2
    for nom in "${a[@]}"; do
        if ! "$APTCACHE" show "$nom" >/dev/null 2>&1; then
            refuse "paquet inconnu : $nom (liste inchangée)"
        fi
    done
    # Ce qui est déjà installé avant l'installation vient de l'image : marqué.
    for nom in "${a[@]}"; do
        if installe "$nom"; then
            deja="$deja $nom"
        fi
    done
    if en_root DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "${a[@]}"; then
        while IFS= read -r ligne; do
            entrees+=("$ligne")
        done < <(lignes_liste)
        for nom in "${a[@]}"; do
            if nom_listee "$nom"; then
                continue
            fi
            case " $deja " in
                *" $nom "*)
                    entrees+=("$nom $PRESENT")
                    echo "$nom : déjà présent avant devzone paquets (marqué ; retirer le laissera installé)"
                    ;;
                *) entrees+=("$nom") ;;
            esac
        done
        ecrire_liste "${entrees[@]}"
    else
        refuse "installation impossible : ${a[*]} (liste inchangée)"
    fi
}

retirer() {
    local -a a=()
    local -a desinstalles=()
    local -a restantes=()
    local arg nom ligne nom_ligne
    for arg in "$@"; do
        case "$arg" in
            -*) refuse "argument inconnu : $arg (devzone paquets retirer <nom>…)" ;;
            *) a+=("$arg") ;;
        esac
    done
    [ "${#a[@]}" -gt 0 ] || refuse "retirer attend au moins un nom : devzone paquets retirer <nom>…"
    for nom in "${a[@]}"; do
        nom_listee "$nom" ||
            refuse "paquet non listé : $nom (fourni par l'image ?) : devzone paquets retirer n'ajoute pas les paquets de l'image"
        if ! marque_presente "$nom"; then
            desinstalles+=("$nom")
        fi
    done
    if [ "${#desinstalles[@]}" -gt 0 ] && ! en_root "$APT" remove -y "${desinstalles[@]}"; then
        refuse "désinstallation impossible : ${desinstalles[*]} (liste inchangée)"
    fi
    for nom in "${a[@]}"; do
        if marque_presente "$nom"; then
            echo "$nom : retiré de la liste, laissé installé (présent avant devzone paquets)"
        fi
    done
    while IFS= read -r ligne; do
        nom_ligne="${ligne%% *}"
        case " ${a[*]} " in
            *" $nom_ligne "*) ;;
            *) restantes+=("$ligne") ;;
        esac
    done < <(lignes_liste)
    ecrire_liste "${restantes[@]+"${restantes[@]}"}"
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
    maj_index || echo "index apt non mis à jour" >&2
    for paquet in "${manquants[@]}"; do
        en_root DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "$paquet" || true
    done
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
