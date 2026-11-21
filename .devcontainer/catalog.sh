#!/usr/bin/env bash
# Application catalog (#414): one preconfigured application per folder
# .devcontainer/catalog/<app>/ (app.conf; the chart charts/devzone-<app>, #559),
# installed in the devzone services cluster under the namespace of its app.conf;
# the wanted state is the line <app>=on|off of .devzone.modules.
#   catalog.sh sync | apply | list | resume | json | remove <app>
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_ROOT:-$(dirname "$ICI")}"
ETAT="${DEVZONE_STATE:-$RACINE/.devzone.modules}"
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

refuse() { echo "devzone : catalog : $*" >&2; exit 2; }

# Catalog folder (overridable by the tests)
catalog_dir() { echo "${DEVZONE_CATALOG:-$ICI/catalog}"; }

# Catalog applications: folders holding an app.conf, sorted
catalog_apps() {
    local d
    for d in "$(catalog_dir)"/*; do
        [ -f "$d/app.conf" ] || continue
        echo "${d##*/}"
    done | LC_ALL=C sort
}

# app.conf key (nom, description, image, port, memoire, taille, namespace)
app_read() {
    grep -E "^$2=" "$(catalog_dir)/$1/app.conf" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Application namespace: the one of app.conf (required)
app_namespace() {
    local ns
    ns="$(app_read "$1" namespace)"
    [ -n "$ns" ] || refuse "missing namespace in app.conf of $1"
    echo "$ns"
}

# Failure marker of an application: same scheme as the failure file of the modules
failure_file() { echo "$ETAT-echec-$1"; }

# Wanted state: on if the line <app>=on exists, off by default
wanted() {
    local v
    v="$(grep -E "^$1=" "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [ "$v" = on ] && echo on || echo off
}

# Application present in the cluster. In the Kubernetes workspace pod: its
# service resolves in the cluster DNS (no RBAC needed, #515). Elsewhere: labelled
# namespace and StatefulSet of the app name; reading the namespaces is reserved
# to the administrator (#430). Nothing without a chosen cluster or when absent.
present() {
    local ctx ns
    ns="$(app_namespace "$1")"
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        # In the pod there is no kubeconfig and the limited service account
        # cannot list StatefulSets (#430): presence is the cluster DNS
        # resolving the service, no RBAC needed, the pod service account
        # stays limited
        getent hosts "$(app_read "$1" nom).${ns}.svc" >/dev/null 2>&1
        return
    fi
    ctx="$(cluster_saved)"
    [ -n "$ctx" ] || return 1
    account_admin "$ctx" get namespace "$ns" >/dev/null 2>&1 &&
        kubectl --context devzone -n "$ns" get statefulset "$1" >/dev/null 2>&1
}

# Application ready: the StatefulSet has one ready replica
app_ready() {
    local ns
    ns="$(app_namespace "$1")"
    [ "$(kubectl --context devzone -n "$ns" get statefulset "$1" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" = 1 ]
}

# Adds to the state the <app>=off lines of the absent applications (once each,
# an existing line is never changed), preceded once by the comment; reading and
# writing hold the same lock (#417): a concurrent write cannot be lost between the two
catalog_sync() (
    local app header missing="" tmp
    [ -f "$ETAT" ] || return 0
    header="# Catalog applications: set to on to install (devzone catalog)"
    state_lock_take || return 1
    # The lock is released on exit, including on an error under set -e
    trap 'state_lock_release' EXIT
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        grep -qE "^${app}=" "$ETAT" 2>/dev/null && continue
        missing="${missing}${missing:+$'\n'}${app}=off"
    done <<<"$(catalog_apps)"
    [ -n "$missing" ] || return 0
    tmp="$(mktemp)"
    {
        cat "$ETAT"
        grep -qF -e "$header" "$ETAT" || echo "$header"
        echo "$missing"
    } >"$tmp"
    state_replace "$tmp"
    rm -f "$tmp"
)

# Real state of an application: available, expected, installed, failed. These
# values are the etat field of devzone status --json: keep them
app_state() {
    local app="$1"
    if [ "$(wanted "$app")" != on ]; then
        echo available
    elif [ -f "$(failure_file "$app")" ]; then
        echo failed
    elif present "$app"; then
        echo installed
    else
        echo expected
    fi
}

# devzone catalog: name, state (off, on installed, on failed), description
catalog_list() {
    local app state label
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        state="$(app_state "$app")"
        case "$state" in
            available) label='off available' ;;
            installed) label='on installed' ;;
            failed) label='on failed' ;;
            *) label='on expected' ;;
        esac
        printf '  %-12s %-14s %s\n' "$app" "$label" "$(app_read "$app" description)"
    done <<<"$(catalog_apps)"
}

# Relay of the installed application: state of its script, else the relay pid
app_relay_stopped() {
    local app="$1" script state
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        # In the pod, no relay: the access goes through the workspace ports
        return 1
    fi
    script="$ICI/catalog/$app/$app.sh"
    if [ -f "$script" ]; then
        state="$(bash "$script" status 2>/dev/null || true)"
        case "$state" in *"relay stopped"*) return 0 ;; esac
    fi
    ! relay_active "$app"
}

# Application lines of devzone's summary: ○ available, ✔ installed (relay
# address), ✖ failed, ⚠ expected
catalog_summary() {
    local app
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        case "$(app_state "$app")" in
            available) printf '  ○ application %-12s available, %s: devzone enable %s\n' \
                "$app" "$(app_read "$app" description)" "$app" ;;
            installed)
                if app_relay_stopped "$app"; then
                    printf '  ⚠ application %-12s installed, relay stopped: devzone repair\n' "$app"
                else
                    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
                        printf '  ✔ application %-12s installed: local access: devzone workspace ports\n' "$app"
                    else
                        printf '  ✔ application %-12s installed: 127.0.0.1:%s\n' \
                            "$app" "$(app_read "$app" port)"
                    fi
                fi ;;
            expected) printf '  ⚠ application %-12s expected: devzone apply\n' "$app" ;;
            *) printf '  ✖ application %s failed: %s: devzone apply\n' \
                "$app" "$(head -1 "$(failure_file "$app")")" ;;
        esac
    done <<<"$(catalog_apps)"
    app_unused_mysql_volumes 2>/dev/null || true
}

# Applications section of devzone status --json: same fields as the modules
catalog_json() {
    local app active state failure cmd json='[]'
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        active=false
        [ "$(wanted "$app")" = on ] && active=true
        state="$(app_state "$app")"
        failure=""
        cmd="devzone apply"
        case "$state" in
            available) cmd="devzone enable $app" ;;
            installed) cmd="devzone disable $app" ;;
            failed) failure="$(head -1 "$(failure_file "$app")")" ;;
        esac
        json="$(jq -cn --argjson before "$json" --arg nom "$app" --argjson actif "$active" \
            --arg description "$(app_read "$app" description)" \
            --arg etat "$state" --arg port "$(app_read "$app" port)" \
            --arg failure "$failure" --arg command "$cmd" \
            '$before + [{nom:$nom,actif:$actif,description:$description,port:$port,etat:$etat,echec:(if $failure=="" then null else $failure end),commande:(if $command=="" then null else $command end)}]')"
    done <<<"$(catalog_apps)"
    printf '%s\n' "$json"
}

case "${1:-}" in
    sync) catalog_sync ;;
    apply) catalog_apply ;;
    list) catalog_list ;;
    resume) catalog_summary ;;
    json) catalog_json ;;
    # Removal of an application: StatefulSet and service, volume kept (#441)
    remove) app_remove "$2" ;;
    -h | --help | aide) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        echo "devzone : catalog : sync | apply | list | resume | json | remove <app>" >&2
        exit 1
        ;;
esac
