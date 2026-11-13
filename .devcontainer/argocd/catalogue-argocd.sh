#!/usr/bin/env bash
# Argo CD for the catalogue applications in the container (#538): the module
# mysql and the catalogue install their application as the Application
# devzone-<app> (services.sh) when the module argocd is active, instead of
# the manifest applied by hand. The namespace (compte_namespace of
# cluster.sh, isolement.sh) and the secret <app>-admin (mirror
# workspace/.<app>/) stay created apart, out of Git; Argo CD holds the chart
# charts/devzone-<app> of the devzone repository at the revision.
#   catalogue_argocd_active <app>            on, installed, chart and revision
#   catalogue_argocd_apply <app> <ns> ...    the Application, then refreshed
#   catalogue_argocd_application_exists <app>
#   catalogue_argocd_delete <app>            Application deleted (namespace
#                                            and volumes stay)
# argocd_revision: DEVZONE_ARGOCD_REVISION, else v<package.json version>;
# empty on a development clone (0.0.0): the local chart is not in Git, the
# manifest path keeps serving. The includer defines RACINE and ETAT (the
# devzone modules file), and the secret hook services_secret_<app> (mirrored,
# never printed). bash 3.2 (macOS).

CATALOGUE_ARGOCD_WIRED="${CATALOGUE_ARGOCD_WIRED:-}"

# Line argocd=on of .devzone.modules of the container
catalogue_argocd_module_on() {
    grep -E '^argocd=' "${ETAT:-}" 2>/dev/null | tail -1 | cut -d= -f2- | grep -qx on
}

# Git revision for the Applications: DEVZONE_ARGOCD_REVISION, else the tag of
# the package version of the image; empty on a development clone
argocd_revision() {
    local version
    if [ -n "${DEVZONE_ARGOCD_REVISION:-}" ]; then
        printf '%s' "$DEVZONE_ARGOCD_REVISION"
        return 0
    fi
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$RACINE/package.json" | head -1)"
    case "$version" in
        '' | 0.0.0) ;;
        *) printf 'v%s' "$version" ;;
    esac
}

# Sources the shared pieces once: conf.sh and gitops.sh with the
# .argocd.conf of the devzone folder, services.sh with the hooks of the
# container (limited devzone context)
catalogue_argocd_load() {
    [ -n "$CATALOGUE_ARGOCD_WIRED" ] && return 0
    # shellcheck disable=SC2034 # read by apps.sh
    APPS_CMD="devzone argocd app"
    # shellcheck disable=SC2034 # read by apps.sh and services.sh
    APPS_GENERATOR="$RACINE/.devcontainer/argocd/application.sh"
    # shellcheck disable=SC2034 # read by gitops.sh
    GITOPS_CMD="devzone argocd init"
    # shellcheck disable=SC2034 # read by conf.sh and apps.sh
    ARGOCD_CONF_DIR="$RACINE"
    # shellcheck disable=SC2034
    ARGOCD_CONF="${DEVZONE_ARGOCD_CONF:-$RACINE/.argocd.conf}"
    # shellcheck source=SCRIPTDIR/conf.sh
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/conf.sh"
    # shellcheck source=SCRIPTDIR/gitops.sh
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/gitops.sh"
    # shellcheck source=SCRIPTDIR/services.sh
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/services.sh"
    # shellcheck disable=SC2034 # read by services.sh
    DEVZONE_REPO_URL="${DEVZONE_REPO_URL:-https://github.com/SimBienvenueHoulBoumi/devzone.git}"
    CATALOGUE_ARGOCD_WIRED=1
}

# The catalogue application <app> can be an Argo CD Application: the module
# argocd is on and installed, the chart exists in charts/, the revision is
# known (a development clone keeps the manifest path)
catalogue_argocd_active() {
    local app="$1"
    catalogue_argocd_module_on || return 1
    [ -d "$RACINE/charts/devzone-$app" ] || return 1
    compte_admin "$(compte_ctx)" get namespace devzone-argocd >/dev/null 2>&1 || return 1
    catalogue_argocd_load
    [ -n "$(argocd_revision)" ]
}

# Applies the Application devzone-<app> (kind service) with the chart
# charts/devzone-<app> at the revision; image, port, memory and size are the
# values of app.conf passed as helm parameters, <extra> holds the ones of the
# application itself (claim). In the GitOps repository when one is designated
# (.argocd.conf), applied directly otherwise (gitops.sh)
catalogue_argocd_apply() {
    local app="$1" ns="$2" image="$3" port="$4" memory="$5" size="$6" params extra="${7:-}"
    catalogue_argocd_load
    params="image=$image port=$port memory=$memory size=$size"
    [ -n "$extra" ] && params="$params $extra"
    # shellcheck disable=SC2086
    gitops_apply_application "devzone-$app" service "$ns" "$DEVZONE_REPO_URL" \
        "$(argocd_revision)" "charts/devzone-$app" $params || return 1
    # Argo CD reads Git every 3 min: an immediate refresh of the Application
    kubectl --context devzone -n devzone-argocd annotate application.argoproj.io \
        "devzone-$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

# The Application devzone-<app> exists in devzone-argocd
catalogue_argocd_application_exists() {
    kubectl --context devzone -n devzone-argocd get application.argoproj.io "devzone-$1" >/dev/null 2>&1
}

# Deletes the Application devzone-<app>: its resources go with it, the
# namespace and the volumes stay (the explicit removal of the data keeps its
# own command); nothing to delete when the Application is absent
catalogue_argocd_delete() {
    catalogue_argocd_application_exists "$1" || return 0
    catalogue_argocd_load
    gitops_delete_application "devzone-$1"
}
