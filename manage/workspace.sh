#!/usr/bin/env bash
# Workstation commands for the Kubernetes workspace (#398, #399): drives the
# charts/devzone-workspace chart with host helm and kubectl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Pod, namespace and projects folder inside the container (#399).
POD="devzone-workspace-0"
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
chart_path() {
    printf '%s/charts/devzone-workspace' "$ROOT"
}

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

# Installs or upgrades the workspace in the cluster.
start_workspace() {
    local repo tag image with_image="" args=()
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
    workspace_deploy "$repo" "$tag" "$with_image"
    # Projects of .argocd.conf held too (#516)
    argocd_reconcile || true
    wait_for_pod "$image" || return 1
    ports_start silence
}

# helm direct: the chart of the package, image set by the options
workspace_helm_deploy() {
    local repo="$1" tag="$2" with_image="$3" args=()
    args=(--namespace devzone-workspace --create-namespace)
    if [ -n "$with_image" ]; then
        args+=(--set "image.repository=$repo" --set "image.tag=$tag")
    else
        args+=(--set "image.tag=$tag")
    fi
    # latest moves at every release: an image already on the node would stay
    # the old one with IfNotPresent (#515)
    if [ "$tag" = latest ]; then
        args+=(--set "image.pullPolicy=Always")
    fi
    # shellcheck disable=SC2046
    helm $(helm_flag) upgrade --install devzone-workspace "$(chart_path)" "${args[@]}"
}

# Uninstalls the workspace from the cluster (Argo CD Application or helm release).
stop_workspace() {
    ports_stop
    workspace_undeploy
}

# Shows workspace pod status.
status_workspace() {
    # shellcheck disable=SC2046
    kubectl $(kubectl_flag) get pods --namespace devzone-workspace
}

# Opens a shell in the workspace container.
shell_workspace() {
    # shellcheck disable=SC2046
    kubectl $(kubectl_flag) exec -it devzone-workspace-0 \
        --namespace devzone-workspace -c workspace -- bash
}

# VS Code steps (#399): attach to the pod with Kubernetes and Dev Containers
# extensions, without any command other than devzone.
vscode_workspace() {
    cat <<EOF
Attach VS Code to the pod: "Kubernetes" and "Dev Containers" extensions
  1. kubectl context: devzone — namespace $NAMESPACE, pod $POD, container workspace
  2. Kubernetes view: right-click the workspace container,
     "Attach to Running Kubernetes Container"
     (with Dev Containers extension: "Dev Containers: Attach to Running Container")
  3. Open folder $PROJECTS_DIR in the attached window
Pod not ready: devzone workspace status
EOF
}

# Copies a workstation folder to $PROJECTS_DIR in the pod (#399, kubectl cp):
# the project keeps its folder name in the pod.
copy_to() {
    local folder="${1:-}"
    if [ -z "$folder" ]; then
        echo "✖ provide a workstation folder: devzone workspace copy-to <folder>" >&2
        exit 1
    fi
    if [ ! -d "$folder" ]; then
        echo "✖ folder not found: $folder" >&2
        exit 1
    fi
    folder="$(cd "$folder" && pwd)"
    # shellcheck disable=SC2046
    kubectl $(kubectl_flag) cp "$folder" "$POD:$PROJECTS_DIR/$(basename "$folder")" \
        --namespace "$NAMESPACE" -c workspace
}

# Copies a project from $PROJECTS_DIR in the pod to the workstation (#399, kubectl cp):
# the workstation folder gets the project name.
copy_from() {
    local folder="${1:-}"
    if [ -z "$folder" ]; then
        echo "✖ provide a workstation folder: devzone workspace copy-from <folder>" >&2
        exit 1
    fi
    # Absolute path: "copy-from ." gives the current folder name.
    folder="$(cd "$folder" 2>/dev/null && pwd || echo "$folder")"
    # shellcheck disable=SC2046
    kubectl $(kubectl_flag) cp "$POD:$PROJECTS_DIR/$(basename "$folder")" "$folder" \
        --namespace "$NAMESPACE" -c workspace
}

# French names of the command and compatibility aliases (lot 3, #508)
# shellcheck source=manage/scripts/workspace-aliases.sh
. "$HERE/scripts/workspace-aliases.sh"
# shellcheck source=manage/scripts/workspace-wait.sh
. "$HERE/scripts/workspace-wait.sh"
# shellcheck source=manage/scripts/migrer.sh
. "$HERE/scripts/migrer.sh"
# shellcheck source=manage/scripts/migrer-retour.sh
. "$HERE/scripts/migrer-retour.sh"
# shellcheck source=manage/scripts/ports-workspace.sh
. "$HERE/scripts/ports-workspace.sh"
# shellcheck source=manage/scripts/services-workspace.sh
. "$HERE/scripts/services-workspace.sh"
# shellcheck source=manage/scripts/argocd-workspace.sh
. "$HERE/scripts/argocd-workspace.sh"
# shellcheck source=manage/scripts/argocd-services.sh
. "$HERE/scripts/argocd-services.sh"

# English command names are accepted, French ones unchanged (#502).
# A copied devzone may miss the aliases file: then no normalization.
# shellcheck source=../.devcontainer/command-aliases.sh
# shellcheck disable=SC1091
if [ -f "$ROOT/.devcontainer/command-aliases.sh" ]; then
    . "$ROOT/.devcontainer/command-aliases.sh"
    if [ "$#" -gt 0 ]; then
        set -- "$(command_canonical "$1")" "${@:2}"
    fi
fi

if [ "$#" -gt 0 ]; then
    set -- "$(workspace_command "$1")" "${@:2}"
fi
if [ "${1:-}" = "ports" ] && [ "$#" -gt 1 ]; then
    set -- "$1" "$(workspace_ports_command "$2")" "${@:3}"
fi

case "${1:-}" in
    start) start_workspace "${@:2}" ;;
    stop) stop_workspace ;;
    status) status_workspace ;;
    shell) shell_workspace ;;
    vscode) vscode_workspace ;;
    copy-to) copy_to "${@:2}" ;;
    copy-from) copy_from "${@:2}" ;;
    ports) ports "${@:2}" ;;
    migrate) migrate_workspace "${@:2}" ;;
    revert) revert_workspace "${@:2}" ;;
    clean-docker) clean_docker "${@:2}" ;;
    services) services "${@:2}" ;;
    argocd) argocd_cmd "${@:2}" ;;
    '' | -h | --help | aide)
        echo "devzone workspace start|stop|status|shell|vscode|copy-to|copy-from|ports|services|argocd|migrate|revert|clean-docker"
        echo "  start [--image repository:tag]  install workspace (image for devzone version by default)"
        echo "  ports [start|stop|status]       applications and services from pod on workstation localhost"
        echo "  services enable|disable <service> [options] | status"
        echo "                        devzone services (gitlab, postgres, argocd) of the cluster, installed from the workstation"
        echo "  argocd status | init [--repo <url>|--none] | apply | app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>"
        echo "                        Argo CD of the workspace: .argocd.conf, GitOps repository, your projects as Applications"
        echo "  migrate [--yes]        copy Docker workstation to Kubernetes workspace (nothing is deleted)"
        echo "  revert [--bring-back]  back to Docker workstation; --bring-back: copy pod projects first"
        echo "  clean-docker           remove devzone-* Docker volumes, after confirmation [y/N] (--yes)"
        ;;
    *)
        echo "✖ unknown subcommand: $1 (devzone workspace start|stop|status|shell|vscode|copy-to|copy-from|ports|services|argocd|migrate|revert|clean-docker)" >&2
        exit 1
        ;;
esac
