#!/usr/bin/env bash
# Module postgres (#280): shared PostgreSQL in the devzone cluster (cluster.sh),
# one database and one user per project.
#   postgres.sh install | uninstall | status | relay-start | relay-stop
#   postgres.sh create <project> [--new-password]   database, role, workspace/.postgres/<project>.env
#   postgres.sh list                                databases and owners
#   postgres.sh psql [<project>]                    console in the pod
#   postgres.sh delete <project> [--yes]            database, role and .env file
# Secrets in workspace/.postgres/ (600, ignored by git), never displayed.
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
# shellcheck disable=SC2034 # read by cluster.sh (sourced library)
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../cluster.sh
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../password.sh
# shellcheck disable=SC1091
. "$ICI/../password.sh"
# shellcheck source=SCRIPTDIR/../chart-direct.sh
# shellcheck disable=SC1091
. "$ICI/../chart-direct.sh"
# Network isolation: namespace_isolate, which provides the NetworkPolicies
# shellcheck source=SCRIPTDIR/../isolation.sh
# shellcheck disable=SC1091
. "$ICI/../isolation.sh"

NS=devzone-postgres
SECRETS="$RACINE/workspace/.postgres"
# Container port where the relay makes PostgreSQL reachable
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_ATTENTE="${POSTGRES_ATTENTE:-300}"
POSTGRES_TAILLE="${POSTGRES_TAILLE:-5Gi}"

refuse() { echo "devzone : postgres : $*" >&2; exit 2; }

# Grouped credentials view: a failure never blocks the operation
regenerate_credentials() {
    password_regenerate ||
        echo "devzone : postgres : grouped credentials not updated (devzone passwords)" >&2
}

# Module context: the devzone cluster; without a choice nothing is
# installed (devzone enable postgres sets it)
module_context() {
    local c
    c="$(cluster_saved)"
    [ -n "$c" ] || refuse "no cluster chosen: devzone enable postgres"
    echo "$c"
}

k() {
    kubectl --context devzone -n "$NS" "$@"
}

# Namespace present in the services cluster: reading namespaces is
# reserved to the administrator (#430)
is_installed() {
    account_admin "$(account_context)" get namespace "$NS" >/dev/null 2>&1
}

# psql as superuser in the pod: local connection (socket), no password;
# the SQL script goes through stdin, never as a visible argument
psql_admin() {
    k exec -i postgres-0 -c postgres -- psql -v ON_ERROR_STOP=1 -X -q -U postgres "$@"
}

# Project name = role name and database name: simple SQL identifier, never
# to escape, and not a reserved name
validate_project() {
    local p="${1:-}"
    [ -n "$p" ] || refuse "project name missing"
    [[ "$p" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || refuse "invalid project name: $p (lowercase, digits, _; starts with a letter)"
    case "$p" in
        postgres | template0 | template1) refuse "reserved name: $p" ;;
    esac
}

new_password() {
    openssl rand -hex 24
}

# Superuser password: the one in the secret if it already exists in the
# cluster (never regenerated: the database keeps its own), otherwise the local
# file, otherwise a new one
admin_secret() {
    local file="$SECRETS/admin-password" pw
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    if k get secret postgres-admin >/dev/null 2>&1; then
        pw="$(k get secret postgres-admin -o jsonpath='{.data.password}' | base64 -d)"
        (umask 077 && printf '%s' "$pw" >"$file")
        return 0
    fi
    if [ ! -s "$file" ]; then
        (umask 077 && new_password | tr -d '\n' >"$file")
    fi
    k create secret generic postgres-admin --from-file=password="$file" >/dev/null
}

do_install() {
    CTX="$(module_context)"
    cluster_prepare "$CTX"
    # On a new machine, the devzone context must point to the chosen cluster
    # before any resource is created (#396); otherwise, everything stops: message and code
    if ! devzone_context_set "$CTX"; then
        echo "devzone : postgres : cannot set the devzone context on $CTX" >&2
        return 1
    fi
    echo "▶ PostgreSQL on cluster $CTX (namespace $NS)…"
    # Namespace created and labeled by the administrator (#430): the limited
    # account may not create objects outside the devzone-* namespaces
    account_admin "$CTX" create namespace "$NS" --dry-run=client -o yaml |
        account_admin "$CTX" apply -f - >/dev/null
    account_admin "$CTX" label namespace "$NS" "$CLUSTER_LABEL" --overwrite >/dev/null
    # Limited account allowed in the namespace: RoleBinding to edit
    account_allow "$CTX" "$NS"
    admin_secret
    chart_install postgres "$NS" "size=$POSTGRES_TAILLE" || return 1
    echo "▶ Waiting for PostgreSQL (timeout ${POSTGRES_ATTENTE}s)…"
    if ! k rollout status statefulset/postgres --timeout="${POSTGRES_ATTENTE}s" >/dev/null; then
        echo "devzone : postgres : not ready after ${POSTGRES_ATTENTE}s: kubectl --context $CTX -n $NS describe pod postgres-0" >&2
        return 1
    fi
    relay_stop postgres
    relay_start postgres "$CTX" "$NS" svc/postgres "$POSTGRES_PORT:5432"
    echo "✔ PostgreSQL ready: 127.0.0.1:$POSTGRES_PORT in the container"
    echo "  Database for a project: devzone postgres create <project>"
    regenerate_credentials
}

do_uninstall() {
    CTX="$(cluster_saved)"
    relay_stop postgres
    # Uninstall on a new machine: the devzone context is reset to the chosen
    # cluster (otherwise it points to the old one); without it, only the
    # local cleanup takes place
    if [ -n "$CTX" ]; then
        devzone_context_set "$CTX" ||
            echo "devzone : postgres : devzone context not set on $CTX; local cleanup only" >&2
    fi
    if [ -n "$CTX" ] && is_installed; then
        echo "▶ Deleting PostgreSQL and all its databases on ${CTX}…"
        # RoleBinding removed, then namespace deleted by the administrator (#430)
        account_remove "$CTX" "$NS" >/dev/null 2>&1 || true
        account_admin "$CTX" delete namespace "$NS" --wait=true >/dev/null
        cluster_release "$CTX"
    fi
    rm -rf "$SECRETS"
    echo "✔ PostgreSQL uninstalled."
    regenerate_credentials
}

count_databases() {
    psql_admin -At -c "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')" 2>/dev/null || echo "?"
}

do_status() {
    CTX="$(cluster_saved)"
    if [ -z "$CTX" ] || ! is_installed; then
        echo "désactivé"
        return 0
    fi
    if [ "$(k get statefulset postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" != 1 ]; then
        echo "en échec sur $CTX : devzone apply"
    elif ! relay_active postgres; then
        echo "prêt sur $CTX, relais arrêté : devzone apply"
    else
        echo "prêt sur $CTX : 127.0.0.1:$POSTGRES_PORT, $(count_databases) base(s)"
    fi
}

do_create() {
    local project="${1:-}" renew="" file pw arg
    validate_project "$project"
    for arg in "${@:2}"; do
        case "$arg" in
            --new-password) renew=1 ;;
            *) refuse "unknown argument: $arg" ;;
        esac
    done
    CTX="$(module_context)"
    is_installed || refuse "module disabled: devzone enable postgres"
    file="$SECRETS/$project.env"
    # Kept password: an application already configured keeps working
    pw="$(sed -n 's/^DB_PASSWORD=//p' "$file" 2>/dev/null || true)"
    if [ -z "$pw" ] || [ -n "$renew" ]; then
        pw="$(new_password)"
    fi
    # REVOKE ... FROM PUBLIC: a project does not connect to another project's database
    psql_admin <<SQL
SELECT 'CREATE ROLE $project LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$project')\gexec
ALTER ROLE $project PASSWORD '$pw';
SELECT 'CREATE DATABASE $project OWNER $project' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$project')\gexec
REVOKE CONNECT ON DATABASE $project FROM PUBLIC;
GRANT CONNECT ON DATABASE $project TO $project;
SQL
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    (
        umask 077
        cat >"$file" <<ENV
DB_HOST=127.0.0.1
DB_PORT=$POSTGRES_PORT
DB_NAME=$project
DB_USER=$project
DB_PASSWORD=$pw
DB_URL=jdbc:postgresql://127.0.0.1:$POSTGRES_PORT/$project
ENV
    )
    echo "✔ database $project ready; credentials: $file"
    regenerate_credentials
}

do_list() {
    CTX="$(module_context)"
    is_installed || refuse "module disabled: devzone enable postgres"
    psql_admin -At -F ' ' -c "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY 1" |
        awk 'BEGIN { n = 0 } { printf "  %-30s owner %s\n", $1, $2; n++ } END { if (n == 0) print "  (no database: devzone postgres create <project>)" }'
}

do_psql() {
    local project="${1:-}" tty=()
    CTX="$(module_context)"
    is_installed || refuse "module disabled: devzone enable postgres"
    [ -t 0 ] && tty=(-t)
    if [ -n "$project" ]; then
        validate_project "$project"
        k exec -i ${tty[@]+"${tty[@]}"} postgres-0 -c postgres -- psql -U "$project" -d "$project"
    else
        k exec -i ${tty[@]+"${tty[@]}"} postgres-0 -c postgres -- psql -U postgres
    fi
}

do_delete() {
    local project="${1:-}" yes="" arg answer
    validate_project "$project"
    for arg in "${@:2}"; do
        case "$arg" in
            --yes) yes=1 ;;
            *) refuse "unknown argument: $arg" ;;
        esac
    done
    CTX="$(module_context)"
    is_installed || refuse "module disabled: devzone enable postgres"
    if [ -z "$yes" ]; then
        cluster_interactive || refuse "cannot confirm without a terminal: devzone postgres delete $project --yes"
        printf 'Delete database %s and all its data? [o/N] ' "$project" >&2
        read -r answer || answer=""
        case "$answer" in
            o | O | oui) ;;
            *) echo "Abandon: nothing was deleted."; return 0 ;;
        esac
    fi
    psql_admin <<SQL
DROP DATABASE IF EXISTS $project WITH (FORCE);
DROP ROLE IF EXISTS $project;
SQL
    rm -f "$SECRETS/$project.env"
    echo "✔ database $project deleted"
    regenerate_credentials
}

do_relay_start() {
    CTX="$(cluster_saved)"
    if [ -n "$CTX" ] && is_installed; then
        relay_start postgres "$CTX" "$NS" svc/postgres "$POSTGRES_PORT:5432"
    fi
}

do_authorize() {
    local ns="${1:-}"
    [ -n "$ns" ] || { echo "devzone postgres: namespace missing" >&2; return 2; }
    namespace_isolate "$ns"
    echo "devzone postgres: access allowed from $ns to the PostgreSQL service"
}

do_forbid() {
    local ns="${1:-}" patch out
    [ -n "$ns" ] || { echo "devzone postgres: namespace missing" >&2; return 2; }
    # JSON built by jq, never assembled by hand (invalid JSON was silently
    # rejected); a failed patch is displayed and returns a code (#396)
    patch="$(jq -nc '{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}')"
    if ! out="$(kubectl --context devzone -n "$NS" patch networkpolicy devzone-meme-namespace \
        -p "$patch" 2>&1)"; then
        echo "devzone : postgres : cannot remove the access rule of $ns: $out" >&2
        return 1
    fi
    echo "devzone postgres: access forbidden from $ns to the PostgreSQL service"
}

case "${1:-}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
    create) do_create "${@:2}" ;;
    list) do_list ;;
    psql) do_psql "${@:2}" ;;
    delete) do_delete "${@:2}" ;;
    relay-start) do_relay_start ;;
    relay-stop) relay_stop postgres ;;
    authorize) do_authorize "${@:2}" ;;
    forbid) do_forbid "${@:2}" ;;
    *)
        echo "devzone postgres: create <project> [--new-password] | list | psql [<project>] | delete <project> [--yes]" >&2
        exit 1
        ;;
esac
