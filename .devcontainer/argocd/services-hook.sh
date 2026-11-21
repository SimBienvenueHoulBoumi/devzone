#!/usr/bin/env bash
# Services of the container held by Argo CD (#559, step 5). Called by devzone
# (changer) after the state line is written, before the helm-direct path:
#   services-hook.sh <svc> <on|off>
# postgres and mysql with the module argocd installed and held: enable writes
# [services] <svc> = on and reconciles it (services_reconcile, services.sh),
# then waits for the pods and starts the relay; disable removes the
# Application (its resources leave with it, namespace and volumes stay).
# argocd off: the Applications of postgres, mysql and gitlab leave with their
# finalizer dropped first, so the resources stay for the helm-direct path
# (adoption, no recreation); then devzone removes Argo CD.
# Exit codes read by devzone: 0 done through Argo CD (devzone stops there),
# 3 not concerned or released (devzone goes on as before), 1 failed.
# gitlab is not held here: its Application comes from gitlab/argocd.sh (step 4).
# Sourced by the tests with stubs; run as a script by devzone. bash 3.2.

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# RACINE: the code tree (libraries, charts); STATE_RACINE: the devzone folder
# (workspace/ secrets, .argocd.conf), the same folder unless DEVZONE_ROOT says so
RACINE="$(dirname "$(dirname "$ICI")")"
STATE_RACINE="${DEVZONE_ROOT:-$RACINE}"
# shellcheck disable=SC2034 # read by catalog-argocd.sh
ETAT="${DEVZONE_STATE:-$STATE_RACINE/.devzone.modules}"
APP_CONF="$RACINE/.devcontainer/catalog/mysql/app.conf"
HOOK_SERVICES="postgres mysql"

# shellcheck source=SCRIPTDIR/../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/catalog-argocd.sh
# shellcheck disable=SC1091
. "$ICI/catalog-argocd.sh"

# Loads the Argo CD pieces (conf, gitops, services with the context devzone)
# and the list of services reconciled here
hook_load() {
    DEVZONE_ARGOCD_CONF="${DEVZONE_ARGOCD_CONF:-$STATE_RACINE/.argocd.conf}"
    export DEVZONE_ARGOCD_CONF
    catalogue_argocd_load
    # shellcheck disable=SC2034 # read by services.sh (services_reconcile)
    SERVICES_LIST="$HOOK_SERVICES"
}

# The relay script of a service (started once its pods are ready)
hook_script() {
    case "$1" in
        postgres) printf '%s' "$ICI/../postgres/postgres.sh" ;;
        mysql) printf '%s' "$ICI/../catalog/mysql/mysql.sh" ;;
    esac
}

# Waits for the pods of devzone-<svc> to be ready (the Application syncs
# within a few minutes); the relay needs a ready pod to forward to
hook_wait() {
    local ns="devzone-$1" tour=0
    while [ "$tour" -lt 60 ]; do
        if argocd_kubectl -n "$ns" get pods -o name 2>/dev/null | grep -q .; then
            argocd_kubectl -n "$ns" wait --for=condition=Ready pod --all --timeout=300s >/dev/null 2>&1 && return 0
        fi
        tour=$((tour + 1))
        sleep 5
    done
    echo "✖ $1 : pods not ready in devzone-$1 (devzone argocd status)" >&2
    return 1
}

# Starts the relay of the service, after the pods are ready
hook_relay() {
    bash "$(hook_script "$1")" relay-start
}

# Admin secret <svc>-admin of the namespace, created apart and mirrored in
# workspace/.<svc>/admin-password (600); an existing secret is kept, never
# printed. The same mirror the helm-direct installers read.
services_secret_admin() {
    local svc="$1" ns="$2" secret="$3" dir file password=""
    dir="$STATE_RACINE/workspace/.$svc"
    file="$dir/admin-password"
    mkdir -p "$dir"
    chmod 700 "$dir"
    password="$(argocd_kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)" || password=""
    if [ -n "$password" ]; then
        (umask 077 && printf '%s' "$password" >"$file")
    else
        if [ ! -s "$file" ]; then
            (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$file")
        fi
        argocd_kubectl -n "$ns" create secret generic "$secret" --from-file=password="$file" >/dev/null
    fi
    chmod 600 "$file"
}

# Secret hooks of services_reconcile: the superuser secret of each service
services_secret_postgres() { services_secret_admin postgres devzone-postgres postgres-admin; }
# The superuser secret of MySQL, the same way
services_secret_mysql() { services_secret_admin mysql devzone-mysql mysql-admin; }

# Value of a key of the MySQL application file (app.conf, read as text)
app_value() { sed -n "s/^$1=//p" "$APP_CONF" 2>/dev/null | tail -1; }

# Parameters of the MySQL chart: image, port, memory and size of app.conf, and
# the claim of the one existing volume (*-mysql-0); several volumes: refused,
# as the helm-direct installer does (#440)
services_chart_mysql() {
    local liste claim="" image port memoire taille
    image="$(app_value image)"
    port="$(app_value port)"
    memoire="$(app_value memoire)"
    taille="$(app_value taille)"
    liste="$(argocd_kubectl -n devzone-mysql get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '\-mysql-0$' || true)"
    if [ -n "$liste" ]; then
        if [ "$(printf '%s\n' "$liste" | grep -c .)" -gt 1 ]; then
            echo "✖ several MySQL volumes in devzone-mysql: devzone mysql volume <name> picks the mounted one" >&2
            return 2
        fi
        claim=" claim=${liste%-mysql-0}"
    fi
    printf 'image=%s port=%s memory=%s size=%s%s' "${image:-mysql:8.4}" "${port:-3306}" \
        "${memoire:-1Gi}" "${taille:-5Gi}" "$claim"
}

# Enable: through Argo CD only when the module is held (installed, chart and
# revision known); otherwise 3, the helm-direct installer runs as before
hook_on() {
    local svc="$1"
    catalogue_argocd_active "$svc" || return 3
    services_note "$svc" on || return 1
    services_reconcile || return 1
    echo "▶ $svc as an Argo CD Application (charts/devzone-$svc at $(argocd_revision))…"
    hook_wait "$svc" || return 1
    hook_relay "$svc" || return 1
    echo "✔ $svc held by Argo CD ([services] $svc = on in .argocd.conf)"
    return 0
}

# Disable: the Application leaves with its resources (cascade); 3 so that the
# usual uninstall of the service goes on and keeps its data rules
hook_off() {
    local svc="$1"
    catalogue_argocd_application_exists "$svc" || return 3
    services_note "$svc" off || return 1
    gitops_delete_application "devzone-$svc" || return 1
    echo "✔ Application devzone-$svc removed (its resources leave with it)"
    return 3
}

# argocd off: each Application of the services leaves with its finalizer
# dropped first (gitops_delete_application keep): the resources stay for the
# helm-direct path. The module is already off when this runs, so the check
# is on the Application itself, not on the module state.
hook_release() {
    local svc app
    for svc in postgres mysql gitlab; do
        app="devzone-$svc"
        argocd_kubectl -n devzone-argocd get application.argoproj.io "$app" >/dev/null 2>&1 || continue
        argocd_kubectl -n devzone-argocd patch application.argoproj.io "$app" --type merge \
            -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        gitops_delete_application "$app" keep || return 1
        case "$svc" in
            postgres | mysql) services_note "$svc" off || return 1 ;;
        esac
        echo "✔ Application $app released: its resources stay for the helm-direct path"
    done
    return 3
}

# Dispatch: the pair service and action decides; anything else is not concerned
hook_main() {
    local svc="${1:-}" action="${2:-}"
    case "$svc:$action" in
        argocd:off) hook_load && hook_release ;;
        postgres:on | mysql:on) hook_load && hook_on "$svc" "${@:3}" ;;
        postgres:off | mysql:off) hook_load && hook_off "$svc" ;;
        *) return 3 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    hook_main "$@"
    exit $?
fi
