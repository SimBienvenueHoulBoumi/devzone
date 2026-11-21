#!/usr/bin/env bash
# MySQL of the catalog (#414): create, list, delete, status, relay-start, relay-stop, install, delete-data.
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_ROOT:-$(dirname "$(dirname "$(dirname "$ICI")")")}"
ETAT="${DEVZONE_STATE:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../../cluster.sh"
# shellcheck source=SCRIPTDIR/../../password.sh
# shellcheck disable=SC1091
. "$ICI/../../password.sh"
# shellcheck source=SCRIPTDIR/../../isolation.sh
# shellcheck disable=SC1091
. "$ICI/../../isolation.sh"
# shellcheck source=SCRIPTDIR/volume.sh
# shellcheck disable=SC1091
. "$ICI/volume.sh"
# shellcheck source=SCRIPTDIR/install.sh
# shellcheck disable=SC1091
. "$ICI/install.sh"
# The argocd module on: MySQL installed by an Application (#538)
# shellcheck source=SCRIPTDIR/../../argocd/catalog-argocd.sh
# shellcheck disable=SC1091
. "$ICI/../../argocd/catalog-argocd.sh"
NS=devzone-mysql
SECRETS="$RACINE/workspace/.mysql"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"
MYSQL_MEMOIRE="${MYSQL_MEMOIRE:-1Gi}"
MYSQL_TAILLE="${MYSQL_TAILLE:-5Gi}"
MYSQL_ATTENTE="${MYSQL_ATTENTE:-300}"
# Standard refusal with a message and code 2
refuse() { echo "devzone : catalog mysql : $*" >&2; exit 2; }
# Secret mysql-admin of the services.sh hook: the same as the direct installation
services_secret_mysql() { mysql_secret; }
# Regenerates the .password view (non-blocking failure)
regenerer_identifiants() {
    password_regenerate ||
        echo "devzone : catalog mysql : grouped credentials not updated (devzone passwords)" >&2
}
# Shortcut for kubectl in the devzone-mysql namespace
k() { kubectl --context devzone -n "$NS" "$@"; }
# Does the devzone-mysql namespace exist? Administrator only (#430)
installed() { account_admin "$(account_context)" get namespace "$NS" >/dev/null 2>&1; }
# Context of the module: the one of the devzone cluster
module_context() {
    local c
    c="$(cluster_saved)"
    [ -n "$c" ] || refuse "no cluster chosen: devzone enable mysql"
    echo "$c"
}
# Failure marker of the module (same scheme as devzone's failure_file)
failure_file() { echo "$ETAT-failed-mysql"; }
# Project name: a simple SQL identifier, never escaped, not a reserved name
check_project_name() {
    local p="${1:-}"
    [ -n "$p" ] || refuse "missing project name"
    [[ "$p" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || refuse "invalid project name: $p (lowercase, digits, _; starts with a letter)"
    case "$p" in
        mysql | information_schema | performance_schema | sys) refuse "reserved name: $p" ;;
    esac
}
# Random password for a new project
new_password() { openssl rand -hex 24; }
# Root password: from root.env of an existing installation, else admin-password
root_password() {
    local password
    password="$(sed -n 's/^MYSQL_PASSWORD=//p' "$SECRETS/root.env" 2>/dev/null | tail -1 || true)"
    [ -z "$password" ] && [ -f "$SECRETS/admin-password" ] && password="$(cat "$SECRETS/admin-password" 2>/dev/null || true)"
    [ -n "$password" ] || refuse "MySQL root password not found (workspace/.mysql/root.env)"
    echo "$password"
}
# mysql as superuser in the pod; the password is never shown
mysql_admin() { k exec -i mysql-0 -c mysql -- mysql -uroot -p"$(root_password)" "$@"; }
# Number of databases, system databases excluded
database_count() {
    local n
    n="$(mysql_admin -N -B -e "SHOW DATABASES" 2>/dev/null | grep -vE '^(information_schema|mysql|performance_schema|sys)$' | grep -c . || true)"
    echo "${n:-0}"
}
# Installs the module (the Argo CD path when the argocd module is on)
install_module() {
    local CTX claim
    CTX="$(module_context)"
    if ! devzone_context_set "$CTX"; then
        echo "devzone : catalog mysql : cannot set the devzone context on $CTX" >&2
        return 1
    fi
    echo "▶ MySQL on cluster $CTX (namespace $NS)…"
    if catalogue_argocd_active mysql; then
        mysql_install_argocd "$CTX"
        return
    fi
    account_namespace "$CTX" "$NS"
    namespace_isolate "$NS" >/dev/null
    if k get statefulset mysql >/dev/null 2>&1; then
        echo "devzone : catalog mysql : existing installation in $NS, adopted (volume and root.env kept)"
    else
        mysql_secret
        claim="$(mysql_claim_choose "$NS")" || return 2
        mysql_apply_chart "$NS" "$claim" || return 1
        if ! k rollout status statefulset/mysql --timeout="${MYSQL_ATTENTE}s" >/dev/null; then
            echo "devzone : catalog mysql : not ready after ${MYSQL_ATTENTE}s: kubectl --context $CTX -n $NS describe pod mysql-0" >&2
            return 1
        fi
    fi
    mysql_secret
    relay_start mysql "$CTX" "$NS" svc/mysql 3306:3306
    echo "✔ MySQL ready: 127.0.0.1:$MYSQL_PORT in the container"
    regenerer_identifiants
}
# Deletes the namespace (so the PVCs), keeps workspace/.mysql (#441):
# terminal confirmation [y/N], --yes required otherwise (refusal, code 2)
delete_data() {
    local CTX yes="" arg answer
    for arg in "$@"; do
        case "$arg" in
            --yes) yes=1 ;;
            *) refuse "unknown argument: $arg" ;;
        esac
    done
    if [ -z "$yes" ]; then
        cluster_interactive || refuse "confirmation needs a terminal: devzone mysql delete-data --yes"
        printf 'Delete namespace %s and all its volumes? [y/N] ' "$NS" >&2
        read -r answer || answer=""
        case "$answer" in
            y | Y | yes) ;;
            *) echo "Aborted: nothing was deleted."; return 0 ;;
        esac
    fi
    CTX="$(cluster_saved)"
    [ -n "$CTX" ] || refuse "no cluster chosen: devzone enable mysql"
    installed || refuse "module disabled: devzone enable mysql"
    echo "▶ Deleting MySQL and its volumes on ${CTX}…"
    # The Application goes first (#538): otherwise Argo CD recreates the namespace
    catalogue_argocd_delete mysql >/dev/null 2>&1 || true
    # RoleBinding removed, then the namespace deleted by the administrator (#430)
    account_remove "$CTX" "$NS" >/dev/null 2>&1 || true
    account_admin "$CTX" delete namespace "$NS" --wait=true >/dev/null
    relay_stop mysql
    rm -f "$(failure_file)"
    echo "✔ namespace $NS and volume deleted; workspace/.mysql/root.env kept"
    regenerer_identifiants
}
# State (disabled, failed, ready, relay stopped): read by devzone, keep the words
module_status() {
    local CTX
    CTX="$(cluster_saved)"
    if [ -z "$CTX" ] || ! installed; then
        echo "disabled"
        return 0
    fi
    if [ "$(k get statefulset mysql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" != 1 ]; then
        echo "failed on $CTX: devzone apply"
        return 0
    fi
    if ! relay_active mysql; then
        echo "ready on $CTX, relay stopped: devzone apply"
        return 0
    fi
    echo "ready on $CTX: 127.0.0.1:$MYSQL_PORT, $(database_count) database(s)"
}
# Creates the user and the database of a project; .env in 600, password kept
create_project() {
    local project="${1:-}" renew="" file password arg
    check_project_name "$project"
    for arg in "${@:2}"; do
        case "$arg" in
            --new-password) renew=1 ;;
            *) refuse "unknown argument: $arg" ;;
        esac
    done
    CTX="$(module_context)"
    installed || refuse "module disabled: devzone enable mysql"
    file="$SECRETS/$project.env"
    if [ -z "$renew" ] && [ -s "$file" ]; then
        password="$(sed -n 's/^MYSQL_PASSWORD=//p' "$file" 2>/dev/null | tail -1)"
    else
        password="$(new_password)"
    fi
    mysql_admin <<SQL
CREATE USER IF NOT EXISTS '$project'@'%' IDENTIFIED BY '$password';
ALTER USER '$project'@'%' IDENTIFIED BY '$password';
CREATE DATABASE IF NOT EXISTS $project;
GRANT ALL ON $project.* TO '$project'@'%';
SQL
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    (
        umask 077
        cat >"$file" <<ENV
MYSQL_HOST=127.0.0.1
MYSQL_PORT=$MYSQL_PORT
MYSQL_USER=$project
MYSQL_PASSWORD=$password
MYSQL_URL=jdbc:mysql://127.0.0.1:$MYSQL_PORT/$project
ENV
    )
    echo "✔ database $project ready; credentials: $file"
    regenerer_identifiants
}
# Lists the databases of the server
list_databases() {
    local CTX
    CTX="$(module_context)"
    installed || refuse "module disabled: devzone enable mysql"
    # grep -v exits 1 with no user database: under pipefail, the list stays at 0
    mysql_admin -N -B -e "SHOW DATABASES" 2>/dev/null |
        { grep -vE '^(information_schema|mysql|performance_schema|sys)$' || true; } |
        awk 'BEGIN { n = 0 } { printf "  %-30s\n", $1; n++ } END { if (n == 0) print "  (no database: devzone mysql create <project>)" }'
}
# Deletes the database and the user of a project (confirmation without --yes)
delete_project() {
    local project="${1:-}" yes="" arg answer
    check_project_name "$project"
    for arg in "${@:2}"; do
        case "$arg" in
            --yes) yes=1 ;;
            *) refuse "unknown argument: $arg" ;;
        esac
    done
    CTX="$(module_context)"
    installed || refuse "module disabled: devzone enable mysql"
    if [ -z "$yes" ]; then
        cluster_interactive || refuse "confirmation needs a terminal: devzone mysql delete $project --yes"
        printf 'Delete database %s and its user? [y/N] ' "$project" >&2
        read -r answer || answer=""
        case "$answer" in
            y | Y | yes) ;;
            *) echo "Aborted: nothing was deleted."; return 0 ;;
        esac
    fi
    mysql_admin <<SQL
DROP DATABASE IF EXISTS $project;
DROP USER IF EXISTS '$project'@'%';
SQL
    rm -f "$SECRETS/$project.env"
    echo "✔ database $project deleted"
    regenerer_identifiants
}
# Restarts the relay 127.0.0.1:3306 if the namespace exists
relay_restart() {
    local CTX
    CTX="$(cluster_saved)"
    [ -n "$CTX" ] && installed && relay_start mysql "$CTX" "$NS" svc/mysql 3306:3306
}
case "${1:-}" in
    install) install_module ;;
    delete-data) delete_data "${@:2}" ;;
    status) module_status ;;
    create) create_project "${@:2}" ;;
    list) list_databases ;;
    delete) delete_project "${@:2}" ;;
    volume) mysql_volume "$NS" "${@:2}" ;;
    relay-start) relay_restart ;;
    relay-stop) relay_stop mysql ;;
    *)
        echo "devzone : catalog mysql : create <project> [--new-password] | list | delete <project> [--yes] | volume [<name>] [--delete <name>] [--yes] | delete-data [--yes]" >&2
        exit 1
        ;;
esac
