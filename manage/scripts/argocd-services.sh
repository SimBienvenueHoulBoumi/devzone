#!/usr/bin/env bash
# Deployments held by Argo CD in the Kubernetes workspace (#516), sourced by
# manage/workspace.sh after argocd-workspace.sh: the workspace itself, the
# postgres service, the argocd services switch and devzone workspace argocd.
#   workspace_deploy <repository> <tag> <with-image>   start: Application, else helm direct
#   workspace_undeploy                                 stop: Application, else helm uninstall
#   argocd_toggle enable|disable                       devzone workspace services … argocd
#   postgres_argocd enable|disable [--yes]             postgres as an Application
#   argocd_cmd status | init | apply | app add|list|remove   devzone workspace argocd …
# Secrets stay out of Git: created here, only referenced by the charts.
# bash 3.2 (macOS).

WORKSPACE_APP="devzone-workspace"
POSTGRES_APP="devzone-postgres"
POSTGRES_NS="devzone-postgres"

# The only option of a removal: --yes (--oui still accepted); prints 1 or 0
yes_flag() {
    local usage="$1" arg found=0
    shift
    for arg in "$@"; do
        case "$arg" in
            --yes | --oui) found=1 ;;
            *) echo "✖ unknown option: $arg (devzone workspace $usage)" >&2; return 1 ;;
        esac
    done
    echo "$found"
}

# [y/N] in a terminal; without one, --yes is required
confirm_removal() {
    local answer=""
    [ "${2:-0}" = 1 ] && return 0
    if [ ! -t 0 ]; then
        echo "✖ no terminal: confirmation impossible, run again with --yes" >&2
        return 1
    fi
    read -r -p "$1 [y/N] " answer || true
    case "$answer" in y | Y | yes | YES | o | O | oui) return 0 ;; esac
    echo "✖ cancelled, nothing changed" >&2
    return 1
}

# shellcheck disable=SC2034 # read by apps.sh
APPS_CMD="devzone workspace argocd app"
# shellcheck disable=SC2034 # read by apps.sh
APPS_GENERATOR="$RACINE/.devcontainer/argocd/application.sh"
# shellcheck disable=SC2034 # read by gitops.sh
GITOPS_CMD="devzone workspace argocd init"
# .argocd.conf of the devzone folder of the workstation (conf.sh)
# shellcheck disable=SC2034 # read by conf.sh and apps.sh
ARGOCD_CONF_DIR="$PWD"
# shellcheck disable=SC2034
ARGOCD_CONF="$PWD/.argocd.conf"
# shellcheck source=../../.devcontainer/argocd/conf.sh
# shellcheck disable=SC1091
. "$RACINE/.devcontainer/argocd/conf.sh"
# shellcheck source=../../.devcontainer/argocd/gitops.sh
# shellcheck disable=SC1091
. "$RACINE/.devcontainer/argocd/gitops.sh"
# shellcheck source=../../.devcontainer/argocd/apps.sh
# shellcheck disable=SC1091
. "$RACINE/.devcontainer/argocd/apps.sh"
argocd_kubectl() { ak "$@"; }

# workspace start and argocd apply: the declarations of .argocd.conf held
argocd_reconcile() {
    argocd_installed || return 0
    gitops_init || return 1
    gitops_root || return 1
    apps_reconcile
}

# Root token of the devzone GitLab for app add: the file of the workstation,
# else the one of the pod (the module was installed there, #528); never printed
apps_gitlab_token() {
    if [ -s "$PWD/workspace/.gitlab/root-token" ]; then
        cat "$PWD/workspace/.gitlab/root-token"
    else
        ak -n "$NAMESPACE" exec "$POD" -c workspace -- cat "$DOSSIER_PROJETS/workspace/.gitlab/root-token" 2>/dev/null || true
    fi
}

# Argo CD holds the devzone charts only with a Git revision (release tag or
# DEVZONE_ARGOCD_REVISION): a development clone stays on helm direct
argocd_holds_charts() {
    argocd_active && [ -n "$(argocd_revision)" ]
}

argocd_clone_notice() {
    if argocd_active && [ -z "$(argocd_revision)" ]; then
        echo "ℹ development clone (version 0.0.0): helm direct; DEVZONE_ARGOCD_REVISION=<branch> to go through Argo CD"
    fi
}

# Release secrets of a release deployed with helm before: deleted, so that
# Argo CD adopts the live resources without any helm uninstall (no downtime)
helm_release_forget() {
    ak -n "$2" delete secret -l "owner=helm,name=$1" --ignore-not-found >/dev/null 2>&1 || true
}

workspace_deploy() {
    local repository="$1" tag="$2" with_image="$3" params
    if ! argocd_holds_charts; then
        argocd_clone_notice
        workspace_helm_deploy "$repository" "$tag" "$with_image"
        return
    fi
    params="image.tag=$tag"
    [ -z "$with_image" ] || params="$params image.repository=$repository"
    [ "$tag" != latest ] || params="$params image.pullPolicy=Always"
    # GitOps repository created or designated first, with its root Application
    gitops_init || return 1
    gitops_root || return 1
    echo "▶ Application $WORKSPACE_APP (Argo CD, charts/devzone-workspace at $(argocd_revision))…"
    helm_release_forget devzone-workspace devzone-workspace
    # shellcheck disable=SC2086
    argocd_apply_application "$WORKSPACE_APP" workspace devzone-workspace \
        "$DEVZONE_REPO_URL" "$(argocd_revision)" charts/devzone-workspace $params
}

workspace_undeploy() {
    if argocd_installed && argocd_application_exists "$WORKSPACE_APP"; then
        echo "▶ Application $WORKSPACE_APP deleted (Argo CD removes the pod, the volumes stay)…"
        argocd_delete_application "$WORKSPACE_APP"
    else
        # shellcheck disable=SC2046
        helm $(drapeau_helm) uninstall devzone-workspace --namespace devzone-workspace
    fi
}

# devzone workspace services enable|disable argocd: the workstation installs
# or removes it itself; the state line follows what succeeded
argocd_toggle() {
    local action="$1"
    shift
    if [ "$#" -ne 0 ]; then
        echo "✖ services $action argocd takes no option (got: $*)" >&2
        return 1
    fi
    case "$action" in
        enable) argocd_install && state_note argocd on && gitops_init && gitops_root ;;
        disable) argocd_uninstall && state_note argocd off ;;
    esac
}

# Namespace of the service: labelled, isolated like the other devzone-*
postgres_namespace_prepare() {
    ak create namespace "$POSTGRES_NS" --dry-run=client -o yaml | ak apply -f - >/dev/null
    ak label namespace "$POSTGRES_NS" app.kubernetes.io/managed-by=devzone --overwrite >/dev/null
    ak -n "$POSTGRES_NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: devzone-meme-namespace
  labels:
    app.kubernetes.io/managed-by: devzone
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
EOF
}

# Superuser secret postgres-admin, created apart: an existing secret is kept
# and mirrored; otherwise a password generated on the workstation. Mirror
# workspace/.postgres/admin-password (600) and .password; never printed
postgres_secret_ensure() {
    local dir="$PWD/workspace/.postgres" file password
    file="$dir/admin-password"
    mkdir -p "$dir"
    chmod 700 "$dir"
    password="$(ak -n "$POSTGRES_NS" get secret postgres-admin \
        -o go-template='{{.data.password | base64decode}}' 2>/dev/null)" || password=""
    if [ -n "$password" ]; then
        (umask 077 && printf '%s' "$password" >"$file")
    else
        if [ ! -s "$file" ]; then
            (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$file")
        fi
        ak -n "$POSTGRES_NS" create secret generic postgres-admin --from-file=password="$file" >/dev/null
    fi
    chmod 600 "$file"
    argocd_passwords_refresh
}

postgres_argocd() {
    local action="$1" yes
    shift
    case "$action" in
        enable)
            if [ "$#" -ne 0 ]; then
                echo "✖ postgres through Argo CD takes no option (got: $*)" >&2
                return 1
            fi
            echo "▶ postgres as an Argo CD Application (charts/devzone-postgres at $(argocd_revision))…"
            postgres_namespace_prepare
            postgres_secret_ensure
            argocd_apply_application "$POSTGRES_APP" service "$POSTGRES_NS" \
                "$DEVZONE_REPO_URL" "$(argocd_revision)" charts/devzone-postgres
            echo "✔ Application $POSTGRES_APP declared; status: devzone workspace argocd status; local access: devzone workspace ports"
            ;;
        disable)
            yes="$(yes_flag "services disable postgres [--yes]" "$@")" || return 1
            confirm_removal "Remove PostgreSQL and ALL its databases (Application and namespace $POSTGRES_NS)?" "$yes" || return 1
            argocd_delete_application "$POSTGRES_APP"
            ak delete namespace "$POSTGRES_NS" --wait=true --ignore-not-found >/dev/null
            rm -rf "$PWD/workspace/.postgres"
            argocd_passwords_refresh
            echo "✔ postgres removed: Application, namespace $POSTGRES_NS and databases"
            ;;
    esac
}

# devzone workspace argocd status | app …
argocd_cmd() {
    case "${1:-status}" in
        status | etat) argocd_status ;;
        init)
            gitops_init "${@:2}" || return $?
            if argocd_installed; then gitops_root; fi
            ;;
        apply)
            if ! argocd_installed; then
                echo "✖ Argo CD not installed: devzone workspace services enable argocd" >&2
                return 1
            fi
            argocd_reconcile
            ;;
        app)
            if ! argocd_installed; then
                echo "✖ Argo CD not installed: devzone workspace services enable argocd" >&2
                return 1
            fi
            argocd_app "${@:2}"
            ;;
        *)
            echo "✖ devzone workspace argocd status | init [--repo <url>|--none] | apply | app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>" >&2
            return 1
            ;;
    esac
}
