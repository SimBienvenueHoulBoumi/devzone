#!/usr/bin/env bash
# Verrou d'écriture de l'état des modules, sourcé par etat.sh (#417 et #476)
#   etat_verrou_prendre / etat_verrou_lacher    verrou d'écriture

# Verrou exclusif (mkdir) : une seule écriture à la fois. Le détenteur
# disparu est deviné par l'âge du dossier (aucun kill) et le compteur rend
# le verrou reprenable dans le même processus (initialiser puis ecrire).
etat_verrou_prendre() {
    local age debut
    [ "${ETAT_VERROU_PROF:-0}" -gt 0 ] && { ETAT_VERROU_PROF=$((ETAT_VERROU_PROF + 1)); return 0; }
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
    # flock sérialise l'écriture quand il existe (Linux), mkdir reste seul garde-fou sous macOS (#476, même motif que #461).
    if command -v flock >/dev/null 2>&1; then
        if { exec 8>"${ETAT}.lock"; } && flock -w 10 8; then
            ETAT_VERROU_FLOCK=1
        else
            rm -rf "${ETAT}.verrou" 2>/dev/null || true
            echo "devzone : état verrouillé ailleurs (flock) : ${ETAT}.lock" >&2
            return 1
        fi
    fi
    ETAT_VERROU_PROF=1
    return 0
}

# Rend le verrou pris par ce processus ; profondeur > 1 : détenu encore
etat_verrou_lacher() {
    local prof="${ETAT_VERROU_PROF:-0}"
    [ "$prof" -gt 0 ] || return 0
    [ "$prof" -gt 1 ] && { ETAT_VERROU_PROF=$((prof - 1)); return 0; }
    ETAT_VERROU_PROF=0
    if [ "${ETAT_VERROU_FLOCK:-0}" = 1 ]; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
        ETAT_VERROU_FLOCK=0
    fi
    rm -rf "${ETAT}.verrou" 2>/dev/null || true
    return 0
}