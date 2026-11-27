#!/usr/bin/env bash
# Workstation commands for the Kubernetes workspace (#398, #399): drives the
# charts/devzone-workspace chart with host helm and kubectl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC2034 # read by the argocd scripts and by .devcontainer/argocd/services.sh (shared with the pod)
RACINE="$ROOT"
# Pod, namespace and projects folder inside the container (#399).
# shellcheck disable=SC2034 # read by the scripts sourced from scripts/workspace/
POD="devzone-workspace-0"
# shellcheck disable=SC2034 # read by the scripts sourced from scripts/workspace/
NAMESPACE="devzone-workspace"
PROJECTS_DIR="/workspaces/projets"
# compatibility alias, removed with lot 4 (#509)
# shellcheck disable=SC2034
DOSSIER_PROJETS="$PROJECTS_DIR"

# Helm flag: devzone context if it exists, otherwise current context (no flag).
helm_flag() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        printf -- '--kube-context devzone'
    fi
}

# kubectl flag: devzone context if it exists, otherwise current context (no flag).
kubectl_flag() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        printf -- '--context devzone'
    fi
}

# Chart path in the repository (or installed package).
chart_path() { printf '%s/charts/devzone-workspace' "$ROOT"; }

# Repository of the image published at each devzone release.
IMAGE_REPO="ghcr.io/simbienvenuehoulboumi/devzone-workspace"

# Why: without tag, the chart takes its appVersion (0.1.0), an image never
# published; the package version is published at each release, and a
# development clone (0.0.0) uses latest.
default_image_tag() {
    local version
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/package.json" | head -1)"
    if [ -z "$version" ] || [ "$version" = "0.0.0" ]; then
        echo "latest"
    else
        echo "$version"
    fi
}

# Installs or upgrades the workspace in the cluster; the cluster is checked first (#565): no Argo CD, helm or pod wait for a stopped one.
start_workspace() {
    local repo tag image with_image="" args=()
    kube_ready_reason --hint >&2 || return 1
    repo="$IMAGE_REPO"
    tag="$(default_image_tag)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --image)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    echo "✖ option --image: provide an image <repository:tag> (devzone workspace start --image <repository:tag>)" >&2
                    return 1
                fi
                case "$2" in
                    *:*)
                        repo="${2%:*}"
                        tag="${2##*:}"
                        with_image=yes
                        ;;
                    *)
                        echo "✖ option --image: image has no tag, expected <repository:tag> (devzone workspace start --image <repository:tag>)" >&2
                        return 1
                        ;;
                esac
                shift 2
                ;;
            *)
                echo "✖ unknown option: $1 (devzone workspace start [--image <repository:tag>])" >&2
                return 1
                ;;
        esac
    done
    image="$repo:$tag"
    # Argo CD first when wanted (#516): the workspace is then an Application
    argocd_ensure
    if [ -n "${DEVZONE_FROM_GO:-}" ] && argocd_active; then devzone workspace deploy "$repo" "$tag" "$with_image"; else workspace_deploy "$repo" "$tag" "$with_image"; fi
    # Projects of .argocd.conf held too (#516)
    argocd_reconcile || true
    wait_for_pod "$image" || return 1
    workspace_agents_guard || true
    ports_start silence
}

# helm direct: the chart of the package, image set by the options
workspace_helm_deploy() {
    local repo="$1" tag="$2" with_image="$3" args=()
    args=(--namespace devzone-workspace --create-namespace)
    [ -z "$with_image" ] || args+=(--set "image.repository=$repo")
    args+=(--set "image.tag=$tag")
    # latest moves at every release: an image already on the node would stay
    # the old one with IfNotPresent (#515)
    [ "$tag" != latest ] || args+=(--set "image.pullPolicy=Always")
    # egress proxy settings (#633), replayed at each start: commas escaped for helm
    for p in $(egress_params | sed 's/,/\\,/g'); do args+=(--set "$p"); done
    # shellcheck disable=SC2046
    helm $(helm_flag) upgrade --install devzone-workspace "$(chart_path)" "${args[@]}"
}

# Uninstalls the workspace from the cluster (Argo CD Application or helm release).
stop_workspace() {
    ports_stop
    workspace_undeploy
}

# Opens a shell in the workspace container.
shell_workspace() {
    # shellcheck disable=SC2046
    kubectl $(kubectl_flag) exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash
}

# shellcheck source=manage/scripts/kube-ready.sh
. "$HERE/scripts/kube-ready.sh"
# shellcheck source=manage/scripts/workspace/workspace-wait.sh
. "$HERE/scripts/workspace/workspace-wait.sh"
# shellcheck source=manage/scripts/workspace/workspace-clone.sh
. "$HERE/scripts/workspace/workspace-clone.sh"
# shellcheck source=manage/scripts/workspace/workspace-copies.sh
. "$HERE/scripts/workspace/workspace-copies.sh"
# shellcheck source=manage/scripts/workspace/ports-workspace.sh
. "$HERE/scripts/workspace/ports-workspace.sh"
# shellcheck source=manage/scripts/workspace/services-workspace.sh
. "$HERE/scripts/workspace/services-workspace.sh"
# shellcheck source=manage/scripts/workspace/argocd-workspace.sh
. "$HERE/scripts/workspace/argocd-workspace.sh"
# shellcheck source=manage/scripts/workspace/argocd-services.sh
. "$HERE/scripts/workspace/argocd-services.sh"
# shellcheck source=manage/scripts/workspace/workspace-update.sh
. "$HERE/scripts/workspace/workspace-update.sh"
# shellcheck source=manage/scripts/workspace/workspace-egress.sh
. "$HERE/scripts/workspace/workspace-egress.sh"

case "${1:-}" in
    start) start_workspace "${@:2}" ;;
    update) update_workspace "${@:2}" ;;
    stop) stop_workspace ;;
    status) status_workspace ;;
    shell) shell_workspace ;;
    ports) ports "${@:2}" ;;
    services) services "${@:2}" ;;
    argocd) argocd_cmd "${@:2}" ;;
    egress) egress_workspace "${@:2}" ;;
    '' | -h | --help | help)
        echo "devzone workspace start|stop|status|shell|ports|services|argocd|update|egress"
        echo "  start [--image repository:tag]  install workspace (image for devzone version by default)"
        echo "  update [--version X.Y.Z] [--yes]  move to the latest stable release (or X.Y.Z); the pod is recreated"
        echo "  ports [start|stop|status]       applications and services from pod on workstation localhost"
        echo "  services enable|disable <service> [options] | status"
        echo "                        devzone services (gitlab, postgres, argocd) of the cluster, installed from the workstation"
        echo "  argocd status | init [--repo <url>|--none] | apply | app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>"
        echo "                        Argo CD of the workspace: .argocd.conf, GitOps repository, your projects as Applications"
        echo "  egress observation|strict|off|status|allow <domain>|deny <domain>   egress proxy of the agent sessions (--pod)"
        ;;
    *)
        echo "✖ unknown subcommand: $1 (devzone workspace start|stop|status|shell|ports|services|argocd|update)" >&2
        exit 1
        ;;
esac
