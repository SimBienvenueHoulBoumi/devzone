#!/usr/bin/env bash
# Module argocd (#411): Argo CD in the devzone services cluster.
#   argocd.sh install | uninstall | status | relay-start | relay-stop
#   argocd.sh app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>
# Isolated devzone-argocd namespace, relay 127.0.0.1:8443 in the container.
# Admin password in workspace/.argocd/admin.env (600), copied to .password;
# never displayed.
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_ROOT:-$(dirname "$(dirname "$ICI")")}"
# shellcheck disable=SC2034 # read by cluster.sh (sourced library)
ETAT="${DEVZONE_STATE:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../password.sh
# shellcheck disable=SC1091
. "$ICI/../password.sh"
# Network isolation: namespace_isolate, applied with the devzone-argocd namespace
# shellcheck source=SCRIPTDIR/../isolation.sh
# shellcheck disable=SC1091
. "$ICI/../isolation.sh"
# Shared memory check of the services cluster (#608): quantity_ki and
# memory_cluster_ki.
# shellcheck source=SCRIPTDIR/../memory.sh
# shellcheck disable=SC1091
. "$ICI/../memory.sh"

NS=devzone-argocd
SECRETS="$RACINE/workspace/.argocd"
# Pinned argo-cd chart version, relay port and install wait
ARGOCD_VERSION="${ARGOCD_VERSION:-10.14.0}"
ARGOCD_PORT="${ARGOCD_PORT:-8443}"
ARGOCD_ATTENTE="${ARGOCD_ATTENTE:-600}"

# Module refusal: prefixed message and code 2 (same convention as postgres)
refuse() { echo "devzone : argocd : $*" >&2; exit 2; }

# Grouped credentials view: a failure never blocks the operation
regenerate_credentials() {
    password_regenerate ||
        echo "devzone : argocd : grouped credentials not updated (devzone passwords)" >&2
}

# Refuses the install below 1 GB of allocatable memory in the cluster; the
# message says where to enlarge the cluster and the command to run again.
check_memory() {
    local mem
    if ! mem="$(memory_cluster_ki)"; then
        echo "devzone : argocd : services cluster unreachable: devzone cluster" >&2
        return 2
    fi
    if [ "$mem" -lt 1048576 ]; then
        echo "devzone : argocd : at least 1 GB of allocatable memory is needed in the cluster (available: $((mem / 1024)) MB); enlarge the cluster (Docker Desktop → Settings → Resources) then run again: devzone enable argocd" >&2
        return 2
    fi
}

# Namespace present in the services cluster: Argo CD is installed.
# Reading namespaces is reserved to the administrator (#430).
is_installed() {
    account_admin "$(account_context)" get namespace "$NS" >/dev/null 2>&1
}

# Creates the namespace and labels it through the administrator, allows the
# limited account, then applies the module's isolating NetworkPolicy (#430).
prepare_namespace() {
    local ctx
    ctx="$(account_context)"
    account_admin "$ctx" create namespace "$NS" --dry-run=client -o yaml |
        account_admin "$ctx" apply -f - >/dev/null
    account_admin "$ctx" label namespace "$NS" "$CLUSTER_LABEL" --overwrite >/dev/null
    account_allow "$ctx" "$NS"
    namespace_isolate "$NS"
}

# Reads the initial password from the chart's Secret and writes it to
# workspace/.argocd/admin.env (600); the content is never displayed.
save_admin() {
    local raw pw
    if ! raw="$(kubectl --context devzone -n "$NS" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null)"; then
        echo "devzone : argocd : secret argocd-initial-admin-secret not found" >&2
        return 1
    fi
    pw="$(printf '%s' "$raw" | base64 -d 2>/dev/null || true)"
    if [ -z "$pw" ]; then
        echo "devzone : argocd : admin password unreadable in the secret" >&2
        return 1
    fi
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    (
        umask 077
        cat >"$SECRETS/admin.env" <<ENV
ARGOCD_URL=https://127.0.0.1:$ARGOCD_PORT
ARGOCD_USER=admin
ARGOCD_PASSWORD=$pw
ENV
    )
    chmod 600 "$SECRETS/admin.env"
}

# Installs Argo CD with the pinned chart, prepares the namespace, stores the
# admin password and starts the access relay; idempotent (upgrade --install).
do_install() {
    echo "▶ Checking the allocatable memory of the services cluster…"
    check_memory || return 2
    prepare_namespace
    echo "▶ Installing Argo CD $ARGOCD_VERSION in $NS (chart charts/devzone-argocd)…"
    # Wrapper chart: the dependency argo-cd (pinned in Chart.yaml) is built
    # first, then installed from the local chart (#538)
    helm dependency build "$RACINE/charts/devzone-argocd" >/dev/null
    account_helm "$(account_context)" upgrade --install argocd \
        "$RACINE/charts/devzone-argocd" \
        --namespace "$NS" \
        --create-namespace \
        --timeout "${ARGOCD_ATTENTE}s" \
        --wait
    save_admin
    relay_start argocd devzone "$NS" svc/argocd-server "$ARGOCD_PORT:443"
    regenerate_credentials
    echo "✔ argocd module ready: https://127.0.0.1:$ARGOCD_PORT"
}

# Uninstalls the Helm release and deletes the namespace; the other services
# of the cluster stay, under direct helm. The RoleBinding and the namespace
# are removed by the administrator (#430).
do_uninstall() {
    local ctx
    relay_stop argocd
    if is_installed; then
        echo "▶ Deleting Argo CD on the services cluster…"
        if ! account_helm "$(account_context)" uninstall argocd -n "$NS" >/dev/null 2>&1; then
            echo "devzone : argocd : helm uninstall failed (release already absent?)" >&2
        fi
        ctx="$(account_context)"
        account_remove "$ctx" "$NS" >/dev/null 2>&1 || true
        account_admin "$ctx" delete namespace "$NS" --wait=true >/dev/null
    fi
    rm -rf "$SECRETS"
    echo "✔ argocd module disabled; the services stay, under direct helm."
    regenerate_credentials
}

# Module status: disabled without namespace, ready with the relay active.
# The status texts are read by devzone: keep them unchanged.
do_status() {
    if ! is_installed; then
        echo "disabled"
        return 0
    fi
    if ! relay_active argocd; then
        echo "ready, relay stopped: devzone apply"
    else
        echo "ready: https://127.0.0.1:$ARGOCD_PORT"
    fi
}

# Starts the access relay again only if the Argo CD namespace exists.
do_relay_start() {
    if is_installed; then
        relay_start argocd devzone "$NS" svc/argocd-server "$ARGOCD_PORT:443"
    fi
}

# Applications of the projects (#516): shared with the workstation (apps.sh),
# here with the limited devzone context (aggregate roles of the chart)
# shellcheck disable=SC2034 # read by apps.sh
APPS_CMD="devzone argocd app"
# shellcheck disable=SC2034 # read by apps.sh
APPS_GENERATOR="$ICI/application.sh"
# shellcheck disable=SC2034 # read by apps.sh: GitLab namespace of this instance
APPS_GITLAB_NS="devzone-gitlab${INSTANCE_SUFFIX}"
# shellcheck disable=SC2034 # read by apps.sh
APPS_GITLAB_TOKEN_FILE="$RACINE/workspace/.gitlab/root-token"
# shellcheck disable=SC2034 # read by gitops.sh
GITOPS_CMD="devzone argocd init"
# shellcheck disable=SC2034 # read by conf.sh and apps.sh: .argocd.conf of the instance
ARGOCD_CONF_DIR="$RACINE"
# shellcheck disable=SC2034
ARGOCD_CONF="${DEVZONE_ARGOCD_CONF:-$RACINE/.argocd.conf}"
# shellcheck source=SCRIPTDIR/conf.sh
# shellcheck disable=SC1091
. "$ICI/conf.sh"
# shellcheck source=SCRIPTDIR/gitops.sh
# shellcheck disable=SC1091
. "$ICI/gitops.sh"
# shellcheck source=SCRIPTDIR/apps.sh
# shellcheck disable=SC1091
. "$ICI/apps.sh"
argocd_kubectl() { kubectl --context devzone "$@"; }

case "${1:-}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    status) do_status ;;
    relay-start) do_relay_start ;;
    relay-stop) relay_stop argocd ;;
    init)
        # GitOps repository of the user (#516): created or designated, then
        # the root Application when the module is installed
        gitops_init "${@:2}" || exit $?
        if is_installed; then gitops_root; fi
        ;;
    apply)
        is_installed || refuse "module off: devzone enable argocd"
        gitops_init && gitops_root && apps_reconcile
        ;;
    app)
        if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
            refuse "in the workspace pod, on the workstation: devzone workspace argocd app ${*:2}"
        fi
        is_installed || refuse "module off: devzone enable argocd"
        argocd_app "${@:2}"
        ;;
    *)
        echo "devzone argocd : install | uninstall | status | init [--repo <url>|--none] | apply | app add|list|remove" >&2
        exit 1
        ;;
esac
