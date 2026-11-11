#!/usr/bin/env bash
# Écriture sûre de l'état des modules (#417) : le seul endroit qui pose,
# remplace ou retire une ligne de $ETAT. Un verrou mkdir empêche deux
# écritures simultanées, le temporaire est créé dans le dossier de l'état
# (le mv reste atomique : le fichier n'est jamais absent ni incomplet pour
# un lecteur) et une copie de secours $ETAT.prec précède chaque
# remplacement.
# Bibliothèque sourcée : l'appelant définit ETAT.
#   etat_ecrire <clé> <valeur>    pose ou remplace la ligne <clé>=<valeur>
#   etat_retirer <clé>            retire la ligne <clé>=
#   etat_poser <fichier>          remplace tout l'état par ce fichier
#   etat_verrou_prendre / etat_verrou_lacher    verrou d'écriture
#   etat_recouvrement_marquer     état restauré ou reconstruit (étape 4)
#   etat_recouvrement_attente     0 si les veilleurs doivent encore attendre
#   etat_recouvrement_en_attente  0 si l'état n'est pas encore confirmé
#   etat_recouvrement_confirmer   confirmé par l'utilisateur (appliquer)

# Verrou exclusif (mkdir) : une seule écriture à la fois. Le détenteur
# disparu est deviné par l'âge du dossier (aucun kill) et le compteur rend
# le verrou reprenable dans le même processus (initialiser puis ecrire).
etat_verrou_prendre() {
    local age debut
    if [ "${ETAT_VERROU_PROF:-0}" -gt 0 ]; then
        ETAT_VERROU_PROF=$((ETAT_VERROU_PROF + 1))
        return 0
    fi
    mkdir -p "$(dirname "$ETAT")" || return 1
    debut="$(date +%s)"
    while ! mkdir "${ETAT}.verrou" 2>/dev/null; do
        age="$(stat -c %Y "${ETAT}.verrou" 2>/dev/null || stat -f %m "${ETAT}.verrou" 2>/dev/null || true)"
        if [ -n "$age" ] && [ "$(( $(date +%s) - age ))" -gt 30 ]; then
            rm -rf "${ETAT}.verrou"
            continue
        fi
        if [ "$(( $(date +%s) - debut ))" -ge 10 ]; then
            echo "devzone : état verrouillé ailleurs : ${ETAT}.verrou" >&2
            return 1
        fi
        sleep 1
    done
    ETAT_VERROU_PROF=1
    return 0
}

# Rend le verrou pris par ce processus ; profondeur > 1 : détenu encore
etat_verrou_lacher() {
    local prof="${ETAT_VERROU_PROF:-0}"
    [ "$prof" -gt 0 ] || return 0
    if [ "$prof" -gt 1 ]; then
        ETAT_VERROU_PROF=$((prof - 1))
        return 0
    fi
    ETAT_VERROU_PROF=0
    rm -rf "${ETAT}.verrou" 2>/dev/null || true
    return 0
}

# Sous verrou : remplace tout l'état par le contenu d'un fichier, après
# sauvegarde de l'état actuel dans $ETAT.prec (restauration, migration)
etat_poser() {
    local src="$1" tmp code=0
    [ -f "$src" ] || return 1
    etat_verrou_prendre || return 1
    if [ -f "$ETAT" ]; then
        cp "$ETAT" "${ETAT}.prec" || { etat_verrou_lacher; return 1; }
    fi
    mkdir -p "$(dirname "$ETAT")" || { etat_verrou_lacher; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { etat_verrou_lacher; return 1; }
    cat "$src" >"$tmp" || code=$?
    if [ "$code" -ne 0 ]; then
        rm -f "$tmp"
        etat_verrou_lacher
        return 1
    fi
    mv "$tmp" "$ETAT" || { rm -f "$tmp"; etat_verrou_lacher; return 1; }
    etat_verrou_lacher
    return 0
}

# Sous verrou : nouvelle valeur d'une clé, sans perdre les autres lignes
etat_ecrire() {
    local cle="$1" valeur="$2" tmp code=0
    etat_verrou_prendre || return 1
    if [ -f "$ETAT" ]; then
        cp "$ETAT" "${ETAT}.prec" || { etat_verrou_lacher; return 1; }
    fi
    mkdir -p "$(dirname "$ETAT")" || { etat_verrou_lacher; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { etat_verrou_lacher; return 1; }
    if [ -f "$ETAT" ]; then
        grep -vE "^${cle}=" "$ETAT" >"$tmp" || code=$?
        if [ "$code" -gt 1 ]; then
            rm -f "$tmp"
            etat_verrou_lacher
            return 1
        fi
    fi
    printf '%s=%s\n' "$cle" "$valeur" >>"$tmp" || { rm -f "$tmp"; etat_verrou_lacher; return 1; }
    mv "$tmp" "$ETAT" || { rm -f "$tmp"; etat_verrou_lacher; return 1; }
    etat_verrou_lacher
    return 0
}

# Sous verrou : retire une clé (#417) ; sans état, rien à retirer
etat_retirer() {
    local cle="$1" tmp code=0
    etat_verrou_prendre || return 1
    [ -f "$ETAT" ] || { etat_verrou_lacher; return 0; }
    cp "$ETAT" "${ETAT}.prec" || { etat_verrou_lacher; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { etat_verrou_lacher; return 1; }
    grep -vE "^${cle}=" "$ETAT" >"$tmp" || code=$?
    if [ "$code" -gt 1 ]; then
        rm -f "$tmp"
        etat_verrou_lacher
        return 1
    fi
    mv "$tmp" "$ETAT" || { rm -f "$tmp"; etat_verrou_lacher; return 1; }
    etat_verrou_lacher
    return 0
}

# Signale un état restauré ou reconstruit : les veilleurs attendent (#417)
etat_recouvrement_marquer() {
    date +%s >"${ETAT}.recouvre" 2>/dev/null || true
}

# 0 (à attendre) moins de 60 s après une restauration ou une reconstruction
etat_recouvrement_attente() {
    local marque
    [ -f "${ETAT}.recouvre" ] || return 1
    marque="$(cat "${ETAT}.recouvre" 2>/dev/null || true)"
    case "$marque" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - marque ))" -lt 60 ]
}

# 0 si l'état restauré ou reconstruit n'est pas encore confirmé (#417)
etat_recouvrement_en_attente() {
    [ -f "${ETAT}.recouvre" ]
}

# L'utilisateur a confirmé l'état (devzone appliquer) : plus de garde
etat_recouvrement_confirmer() {
    rm -f "${ETAT}.recouvre" 2>/dev/null || true
    return 0
}
