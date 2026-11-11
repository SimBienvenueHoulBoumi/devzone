#!/usr/bin/env bash
# Détection à chaud du catalogue (#414) : quand .devzone.modules change,
# catalogue.sh appliquer est lancé. Une seule instance (verrou, comme #394).
#   catalogue-veilleur.sh demarrer | arreter | tour
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(cd "$ICI/../.." && pwd)}"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/etat.sh
# shellcheck disable=SC1091
. "$(dirname "$ICI")/etat.sh"
BASE="${DEVZONE_CATALOGUE_VEILLEUR_DIR:-$RACINE/.devzone.catalogue-veilleur}"
VERROU="$BASE/verrou"
DERNIER="$BASE/dernier"

refuse() { echo "devzone : catalogue-veilleur : $*" >&2; exit 2; }

# Garde-fou (#293) : jamais sous bats, seulement avec DEVZONE_CATALOGUE_REEL=oui
garde_veilleur() {
    if [ "${DEVZONE_CATALOGUE_REEL:-}" != oui ]; then
        echo "devzone : catalogue-veilleur : refusé ici (DEVZONE_CATALOGUE_REEL=oui)" >&2
        return 2
    fi
    if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
        echo "devzone : catalogue-veilleur : refusé sous bats (tests)" >&2
        return 2
    fi
    return 0
}

# Verrou exclusif (mkdir) avec pid ; une seule instance du veilleur
verrou_prendre() {
    local debut now age pid
    debut="$(date +%s)"
    while true; do
        if mkdir "$VERROU" 2>/dev/null; then echo "$$" >"$VERROU/pid"; return 0; fi
        now="$(date +%s)"
        age=""; [ -d "$VERROU" ] && age="$(stat -c %Y "$VERROU" 2>/dev/null || stat -f %m "$VERROU" 2>/dev/null || true)"
        pid="$(cat "$VERROU/pid" 2>/dev/null || true)"
        if [ -n "$age" ] && [ "$(( now - age ))" -gt 30 ]; then rm -rf "$VERROU"; continue; fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$VERROU"; continue; fi
        [ "$(( now - debut ))" -ge 5 ] && return 1
        sleep 1
    done
}

# Marque le verrou vivant (date et pid à jour)
verrou_rafraichir() { touch "$VERROU" 2>/dev/null || true; echo "$$" >"$VERROU/pid" 2>/dev/null || true; }

# Un tour : si .devzone.modules a changé depuis le dernier tour, on applique
tour() {
    local maintenant ancien
    [ -f "$ETAT" ] || return 0
    # État restauré ou reconstruit : le veilleur ne suit pas un état douteux,
    # et ne désinstalle jamais tant que devzone appliquer ne l'a pas confirmé
    etat_recouvrement_attente && return 0
    etat_recouvrement_en_attente && return 0
    mkdir -p "$BASE"
    maintenant="$(stat -c %Y "$ETAT" 2>/dev/null || stat -f %m "$ETAT" 2>/dev/null || true)"
    [ -n "$maintenant" ] || return 0
    ancien="$(cat "$DERNIER" 2>/dev/null || true)"
    if [ "$maintenant" != "$ancien" ]; then
        echo "$maintenant" >"$DERNIER"
        echo "devzone : catalogue-veilleur : .devzone.modules modifié, application" >&2
        bash "$ICI/../catalogue.sh" appliquer
    fi
}

# Boucle : un tour toutes les 5 s, verrou rafraîchi à chaque tour
boucle() {
    mkdir -p "$BASE"
    if ! verrou_prendre; then return 0; fi
    trap 'rm -rf "$VERROU"' EXIT INT TERM
    while true; do
        [ -f "$ETAT" ] || { rm -rf "$VERROU"; break; }
        verrou_rafraichir
        tour || true
        sleep 5
    done
}

# Lance la boucle détachée (#435) et vérifie que son verrou vit
lancer_detache() {
    local i pid stable=0 detache=()
    mkdir -p "$BASE"
    # Même détachement que relais_lancer : setsid si présent, sinon nohup.
    command -v setsid >/dev/null 2>&1 && detache=(setsid)
    ${detache[@]+"${detache[@]}"} nohup env DEVZONE_CATALOGUE_REEL=oui bash "$0" boucle >"$BASE/veilleur.log" 2>&1 &
    i=0
    while [ "$i" -lt 20 ]; do
        pid="$(cat "$VERROU/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            stable=$((stable + 1))
            [ "$stable" -ge 5 ] && { echo "lancé"; return 0; }
        else
            stable=0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "devzone : catalogue-veilleur : démarrage impossible, voir $BASE/veilleur.log" >&2
    return 1
}

# Arrête le veilleur et retire le verrou
arreter() {
    local pid
    pid="$(cat "$VERROU/pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$VERROU"
}

case "${1:-}" in
    boucle | loop) if ! garde_veilleur; then exit 2; fi; boucle ;;
    demarrer | start | lancer)
        if ! garde_veilleur; then exit 2; fi
        if [ -f "$VERROU/pid" ] && kill -0 "$(cat "$VERROU/pid")" 2>/dev/null; then
            echo "déjà lancé"
        else
            lancer_detache || exit 1
        fi
        ;;
    arreter | stop) arreter ; echo "arrêté" ;;
    tour | un-tour) tour ;;
    *)
        echo "devzone : catalogue-veilleur : demarrer | arreter | tour" >&2
        exit 2
        ;;
esac
