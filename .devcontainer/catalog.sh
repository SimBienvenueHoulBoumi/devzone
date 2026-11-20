#!/usr/bin/env bash
# Catalogue d'applications (#414) : une application préconfigurée par dossier
# .devcontainer/catalog/<app>/ (app.conf ; le chart charts/devzone-<app>, #559), installée dans le
# cluster des services de devzone sous son namespace de app.conf ; l'état
# voulu est la ligne <app>=on|off de .devzone.modules.
#   catalog.sh sync | apply | list | resume | json | remove <app>
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/cluster.sh
# shellcheck disable=SC1091
. "$ICI/cluster.sh"
# shellcheck source=SCRIPTDIR/state.sh
# shellcheck disable=SC1091
. "$ICI/state.sh"
# shellcheck source=SCRIPTDIR/password.sh
# shellcheck disable=SC1091
. "$ICI/password.sh"
# shellcheck source=SCRIPTDIR/isolation.sh
# shellcheck disable=SC1091
. "$ICI/isolation.sh"
# shellcheck source=SCRIPTDIR/catalog/app.sh
# shellcheck disable=SC1091
. "$ICI/catalog/app.sh"

refuse() { echo "devzone : catalogue : $*" >&2; exit 2; }

# Dossier du catalogue (surchargeable par les tests)
dossier_catalogue() { echo "${DEVZONE_CATALOGUE:-$ICI/catalog}"; }

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

# Application present in the cluster. In the Kubernetes workspace pod: its
# service resolves in the cluster DNS (no RBAC needed, #515). Elsewhere: labelled
# namespace and StatefulSet of the app name; reading the namespaces is reserved
# to the administrator (#430). Nothing without a chosen cluster or when absent.
presente() {
    local ctx ns
    ns="$(app_ns "$1")"
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        # In the pod there is no kubeconfig and the limited service account
        # cannot list StatefulSets (#430): presence is the cluster DNS
        # resolving the service, no RBAC needed, the pod service account
        # stays limited
        getent hosts "$(app_lire "$1" nom).${ns}.svc" >/dev/null 2>&1
        return
    fi
    ctx="$(cluster_lu)"
    [ -n "$ctx" ] || return 1
    compte_admin "$ctx" get namespace "$ns" >/dev/null 2>&1 &&
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
# chacune, jamais une ligne existante modifiée), précédées une fois du
# commentaire ; la lecture et l'écriture tiennent le même verrou (#417) :
# une écriture concurrente ne peut pas être perdue entre les deux
catalogue_synchroniser() (
    local app entete manque="" tmp
    [ -f "$ETAT" ] || return 0
    entete="# Applications du catalogue : passer à on pour installer (devzone catalog)"
    state_lock_take || return 1
    # Le verrou est rendu à la sortie, y compris sur une erreur sous set -e
    trap 'state_lock_release' EXIT
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        grep -qE "^${app}=" "$ETAT" 2>/dev/null && continue
        manque="${manque}${manque:+$'\n'}${app}=off"
    done <<<"$(catalogue_apps)"
    [ -n "$manque" ] || return 0
    tmp="$(mktemp)"
    {
        cat "$ETAT"
        grep -qF "$entete" "$ETAT" || echo "$entete"
        echo "$manque"
    } >"$tmp"
    state_replace "$tmp"
    rm -f "$tmp"
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

# devzone catalog : nom, état (off, on installée, on en échec), description
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
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        # In the pod, no relay: the access goes through the workspace ports
        return 1
    fi
    script="$ICI/catalog/$app/$app.sh"
    if [ -f "$script" ]; then
        etat="$(bash "$script" status 2>/dev/null || true)"
        case "$etat" in *"relais arrêté"*) return 0 ;; esac
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
            disponible) printf '  ○ application %-12s disponible, %s : devzone enable %s\n' \
                "$app" "$(app_lire "$app" description)" "$app" ;;
            installée)
                if app_relais_arrete "$app"; then
                    printf '  ⚠ application %-12s installée, relais arrêté : devzone repair\n' "$app"
                else
                    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
                        printf '  ✔ application %-12s installée : local access: devzone workspace ports\n' "$app"
                    else
                        printf '  ✔ application %-12s installée : 127.0.0.1:%s\n' \
                            "$app" "$(app_lire "$app" port)"
                    fi
                fi ;;
            attendue) printf '  ⚠ application %-12s attendue : devzone apply\n' "$app" ;;
            *) printf '  ✖ application %s en échec : %s : devzone apply\n' \
                "$app" "$(head -1 "$(fichier_echec "$app")")" ;;
        esac
    done <<<"$(catalogue_apps)"
    app_mysql_volumes_inutilises 2>/dev/null || true
}

# Rubrique applications de devzone status --json : mêmes champs que modules
catalogue_json() {
    local app actif etat echec cmd json='[]'
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        actif=false
        [ "$(voulu "$app")" = on ] && actif=true
        etat="$(app_etat "$app")"
        echec=""
        cmd="devzone apply"
        case "$etat" in
            disponible) cmd="devzone enable $app" ;;
            installée) cmd="devzone disable $app" ;;
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
    sync) catalogue_synchroniser ;;
    apply) catalogue_appliquer ;;
    list) catalogue_lister ;;
    resume) catalogue_resume ;;
    json) catalogue_json ;;
    # Retrait d'une application : StatefulSet et service, volume gardé (#441)
    remove) app_desinstaller "$2" ;;
    -h | --help | aide) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        echo "devzone : catalogue : sync | apply | list | resume | json | remove <app>" >&2
        exit 1
        ;;
esac
