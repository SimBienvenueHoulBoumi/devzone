#!/usr/bin/env bash
# Catalogue d'applications (#414) : une application préconfigurée par dossier
# .devcontainer/catalogue/<app>/ (app.conf, manifeste.yaml), installée dans le
# cluster des services de devzone sous son namespace de app.conf ; l'état
# voulu est la ligne <app>=on|off de .devzone.modules.
#   catalogue.sh synchroniser | appliquer | lister | resume | json
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/cluster.sh
# shellcheck disable=SC1091
. "$ICI/cluster.sh"
# shellcheck source=SCRIPTDIR/password.sh
# shellcheck disable=SC1091
. "$ICI/password.sh"
# shellcheck source=SCRIPTDIR/isolement.sh
# shellcheck disable=SC1091
. "$ICI/isolement.sh"
# shellcheck source=SCRIPTDIR/catalogue/app.sh
# shellcheck disable=SC1091
. "$ICI/catalogue/app.sh"

refuse() { echo "devzone : catalogue : $*" >&2; exit 2; }

# Dossier du catalogue (surchargeable par les tests)
dossier_catalogue() { echo "${DEVZONE_CATALOGUE:-$ICI/catalogue}"; }

# Applications du catalogue : dossiers pourvus d'un app.conf, triés
catalogue_apps() {
    local d
    for d in "$(dossier_catalogue)"/*; do
        [ -f "$d/app.conf" ] || continue
        echo "${d##*/}"
    done | LC_ALL=C sort
}

# Clé de app.conf (nom, description, image, port, mémoire, taille, namespace)
app_lire() {
    grep -E "^$2=" "$(dossier_catalogue)/$1/app.conf" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Namespace de l'application : celui de app.conf (requis)
app_ns() {
    local ns
    ns="$(app_lire "$1" namespace)"
    [ -n "$ns" ] || refuse "namespace manquant dans app.conf de $1"
    echo "$ns"
}

# Marque d'échec d'une application : même schéma que fichier_echec des modules
fichier_echec() { echo "$ETAT-echec-$1"; }

# État voulu : on si la ligne <app>=on existe, off par défaut
voulu() {
    local v
    v="$(grep -E "^$1=" "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [ "$v" = on ] && echo on || echo off
}

# Application présente dans le cluster : namespace étiqueté et StatefulSet du
# nom de l'application ; sans cluster choisi ou absente : rien
presente() {
    local ns
    [ -n "$(cluster_lu)" ] || return 1
    ns="$(app_ns "$1")"
    kubectl --context devzone get namespace "$ns" >/dev/null 2>&1 &&
        kubectl --context devzone -n "$ns" get statefulset "$1" >/dev/null 2>&1
}

# Application prête : le StatefulSet compte une réplique prête
app_prete() {
    local ns
    ns="$(app_ns "$1")"
    [ "$(kubectl --context devzone -n "$ns" get statefulset "$1" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" = 1 ]
}

# Ajoute à l'état les lignes <app>=off des applications absentes (une fois
# chacune, jamais une ligne existante modifiée), précédées une fois du commentaire
catalogue_synchroniser() (
    local app entete manque="" tmp
    [ -f "$ETAT" ] || return 0
    entete="# Applications du catalogue : passer à on pour installer (devzone catalogue)"
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        grep -qE "^${app}=" "$ETAT" 2>/dev/null && continue
        manque="${manque}${manque:+$'\n'}${app}=off"
    done <<<"$(catalogue_apps)"
    [ -n "$manque" ] || return 0
    mkdir -p "$(dirname "$ETAT")"
    tmp="$(mktemp)"
    {
        cat "$ETAT"
        grep -qF "$entete" "$ETAT" || echo "$entete"
        echo "$manque"
    } >"$tmp"
    mv "$tmp" "$ETAT"
)

# État réel d'une application : disponible, attendue, installée, echec
app_etat() {
    local app="$1"
    if [ "$(voulu "$app")" != on ]; then
        echo disponible
    elif [ -f "$(fichier_echec "$app")" ]; then
        echo echec
    elif presente "$app"; then
        echo installée
    else
        echo attendue
    fi
}

# devzone catalogue : nom, état (off, on installée, on en échec), description
catalogue_lister() {
    local app etat etiquette
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        etat="$(app_etat "$app")"
        case "$etat" in
            disponible) etiquette='off disponible' ;;
            installée) etiquette="on installée" ;;
            echec) etiquette="on en échec" ;;
            *) etiquette="on attendue" ;;
        esac
        printf '  %-12s %-14s %s\n' "$app" "$etiquette" "$(app_lire "$app" description)"
    done <<<"$(catalogue_apps)"
}

# Relais de l application installee : etat de son script, sinon pid du relais
app_relais_arrete() {
    local app="$1" script etat
    script="$ICI/catalogue/$app/$app.sh"
    if [ -x "$script" ]; then
        etat="$(bash "$script" etat 2>/dev/null || true)"
        case "$etat" in *"relais arrêté"*) return 0 ;; esac
        case "$etat" in *"relais arrete"*) return 0 ;; esac
    fi
    ! relais_actif "$app"
}

# Lignes Applications du récapitulatif de devzone : ○ disponible, ✔ installée
# (adresse du relais), ✖ en échec, ⚠ attendue
catalogue_resume() {
    local app
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        case "$(app_etat "$app")" in
            disponible) printf '  ○ application %-12s disponible, %s : devzone activer %s\n' \
                "$app" "$(app_lire "$app" description)" "$app" ;;
            installée)
                if app_relais_arrete "$app"; then
                    printf '  ⚠ application %-12s installée, relais arrêté : devzone reparer\n' "$app"
                else
                    printf '  ✔ application %-12s installée : 127.0.0.1:%s\n' \
                        "$app" "$(app_lire "$app" port)"
                fi ;;
            attendue) printf '  ⚠ application %-12s attendue : devzone appliquer\n' "$app" ;;
            *) printf '  ✖ application %s en échec : %s : devzone appliquer\n' \
                "$app" "$(head -1 "$(fichier_echec "$app")")" ;;
        esac
    done <<<"$(catalogue_apps)"
}

# Rubrique applications de devzone etat --json : mêmes champs que modules
catalogue_json() {
    local app actif etat echec cmd json='[]'
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        actif=false
        [ "$(voulu "$app")" = on ] && actif=true
        etat="$(app_etat "$app")"
        echec=""
        cmd="devzone appliquer"
        case "$etat" in
            disponible) cmd="devzone activer $app" ;;
            installée) cmd="devzone desactiver $app" ;;
            echec) echec="$(head -1 "$(fichier_echec "$app")")" ;;
        esac
        json="$(jq -cn --argjson avant "$json" --arg nom "$app" --argjson actif "$actif" \
            --arg description "$(app_lire "$app" description)" \
            --arg etat "$etat" --arg port "$(app_lire "$app" port)" \
            --arg echec "$echec" --arg commande "$cmd" \
            '$avant + [{nom:$nom,actif:$actif,description:$description,port:$port,etat:$etat,echec:(if $echec=="" then null else $echec end),commande:(if $commande=="" then null else $commande end)}]')"
    done <<<"$(catalogue_apps)"
    printf '%s\n' "$json"
}

case "${1:-}" in
    synchroniser) catalogue_synchroniser ;;
    appliquer) catalogue_appliquer ;;
    lister) catalogue_lister ;;
    resume) catalogue_resume ;;
    json) catalogue_json ;;
    -h | --help | aide) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        echo "devzone : catalogue : synchroniser | appliquer | lister | resume | json" >&2
        exit 1
        ;;
esac
