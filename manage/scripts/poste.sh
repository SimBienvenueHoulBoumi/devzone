#!/usr/bin/env bash
# Why: make up|shell|stop|rebuild always drives the Docker container, even
# after "devzone workspace migrate", which writes workspace=kubernetes in
# .devzone.modules (#472). This script reads that mode: in Kubernetes it hands
# off to manage/workspace.sh (repo clone) or npx devzone@<version> workspace
# (folder created by npx devzone); in Docker it returns 3 and does nothing, so
# the Makefile keeps its original recipe. The advice target shows, after an
# update, what the workstation can do next (#472).
# Portable: bash 3.2 (macOS) and Linux.
set -uo pipefail

usage() {
    echo "usage: bash manage/scripts/poste.sh up|shell|stop|rebuild|advice <folder>" >&2
}

# Last workspace= value in <folder>/.devzone.modules; missing, empty or not
# kubernetes -> docker.
workspace_mode() {
    local folder="$1" value
    value="$(grep '^workspace=' "$folder/.devzone.modules" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ "$value" = "kubernetes" ]; then
        echo kubernetes
    else
        echo docker
    fi
}

# Folder version: first "version X.Y.Z" line in .devzone.version; unreadable or
# empty -> latest.
folder_version() {
    local folder="$1" version
    version="$(sed -n 's/^version \([^[:space:]]*\)[[:space:]]*$/\1/p' "$folder/.devzone.version" 2>/dev/null | head -1 || true)"
    if [ -z "$version" ]; then
        echo latest
    else
        echo "$version"
    fi
}

# Kubernetes reachable: kubectl and helm present, and kubectl cluster-info
# responds within 5 s (--context devzone if that context is declared).
kube_ready() {
    command -v kubectl >/dev/null 2>&1 || return 1
    command -v helm >/dev/null 2>&1 || return 1
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        kubectl cluster-info --request-timeout=5s --context devzone >/dev/null 2>&1
    else
        kubectl cluster-info --request-timeout=5s >/dev/null 2>&1
    fi
}

# Workspace command for the folder: clone script if present, otherwise the
# published CLI for the folder version, run from the folder.
workspace_cmd() {
    local folder="$1" version
    shift
    if [ -f "$folder/manage/workspace.sh" ]; then
        (cd "$folder" && bash manage/workspace.sh "$@")
    else
        version="$(folder_version "$folder")"
        (cd "$folder" && npx -y "devzone@$version" workspace "$@")
    fi
}

target="${1:-}"
folder="${2:-}"
case "$target" in
    up | shell | stop | rebuild | advice | conseil) ;;
    *)
        usage
        exit 2
        ;;
esac
if [ -z "$folder" ]; then
    usage
    exit 2
fi

# Advice after update: always exit 0, nothing to do in Docker without reachable Kubernetes.
if [ "$target" = "advice" ] || [ "$target" = "conseil" ]; then
    if [ "$(workspace_mode "$folder")" = kubernetes ]; then
        echo "Kubernetes workspace: the new image is used on the next devzone workspace start (or make up)."
    elif kube_ready; then
        echo "Kubernetes reachable: devzone workspace migrate moves this workstation to the cluster (nothing is deleted, rollback: devzone workspace revert)."
    fi
    exit 0
fi

# Docker workstation: Makefile resumes its current recipe (exit 3).
[ "$(workspace_mode "$folder")" = kubernetes ] || exit 3

case "$target" in
    up) workspace_cmd "$folder" start ;;
    shell) workspace_cmd "$folder" start && workspace_cmd "$folder" shell ;;
    stop) workspace_cmd "$folder" stop ;;
    rebuild)
        echo "✖ make rebuild: this workstation is in Kubernetes workspace mode (workspace=kubernetes in .devzone.modules), nothing to rebuild on the machine; back to Docker workstation: devzone workspace revert" >&2
        exit 1
        ;;
esac
