#!/usr/bin/env bash
# Workstation mode at creation (#497): a new devzone is Kubernetes when the
# cluster answers, Docker otherwise. Sourced by manage/devzone (creer):
# create_mode_choose runs before any file is copied (so --kubernetes without a
# cluster creates nothing), create_mode_write once the folder exists.
# Sourced only: no code at file level. Compatible with bash 3.2 (macOS).
# shellcheck disable=SC2034 # CREATE_MODE is read by manage/devzone (creer)
# shellcheck source=manage/scripts/kube-ready.sh
. "$(dirname "${BASH_SOURCE[0]}")/kube-ready.sh"

# Context shown to the user: devzone if declared, otherwise the current one.
kube_context() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        echo devzone
    else
        kubectl config current-context 2>/dev/null || echo none
    fi
}

# Chooses the mode from the option (kubernetes, docker, or empty) and sets
# CREATE_MODE to kubernetes or docker, with one line of notice. Returns 1,
# nothing set on disk, when --kubernetes is asked and the cluster does not
# answer.
create_mode_choose() {
    local option="$1" reason
    if [ "$option" = docker ]; then
        CREATE_MODE=docker
        echo "Docker workstation (--docker): later: devzone workspace migrate"
        return 0
    fi
    if reason="$(kube_ready_reason)"; then
        CREATE_MODE=kubernetes
        echo "✔ Kubernetes ready ($(kube_context)): workspace in the cluster"
        create_mode_existing
        return 0
    fi
    if [ "$option" = kubernetes ]; then
        echo "✖ Kubernetes not reachable: $reason. Nothing created: start the cluster, or create with --docker" >&2
        return 1
    fi
    CREATE_MODE=docker
    echo "⚠ Kubernetes not reachable: $reason. Docker workstation; later: devzone workspace migrate"
    return 0
}

# A workspace already installed in the cluster (helm release devzone-workspace,
# or Argo CD Application devzone-workspace), from any folder: the new folder
# drives it too, and creation goes on (the start is a helm upgrade, the volumes
# stay). Notice only.
create_mode_existing() {
    local ctx
    ctx="$(kube_context)"
    if helm status devzone-workspace --namespace devzone-workspace --kube-context "$ctx" >/dev/null 2>&1 ||
        kubectl get application.argoproj.io devzone-workspace --namespace devzone-argocd --context "$ctx" >/dev/null 2>&1; then
        echo "ℹ a devzone workspace already runs in this cluster: this folder drives it too"
    fi
    return 0
}

# Writes workspace=<mode> in <folder>/.devzone.modules: an earlier workspace=
# line is replaced, the other lines are kept.
create_mode_write() {
    local folder="$1" mode="$2" f
    f="$folder/.devzone.modules"
    {
        if [ -f "$f" ]; then grep -v '^workspace=' "$f" || true; fi
        echo "workspace=$mode"
    } >"$f.tmp" && mv "$f.tmp" "$f"
}

# Kubernetes creation: installs the workspace from the package script, run in
# the new folder (as devzone workspace start does). DEVZONE_WORKSPACE_SH
# replaces the script (tests); DEVZONE_SANS_DEMARRER only prints the command.
create_mode_start() {
    local folder="$1" script="$2"
    if [ -n "${DEVZONE_SANS_DEMARRER:-}" ]; then
        echo "To start the workspace: cd $folder && devzone workspace start"
        return 0
    fi
    echo "▶ Starting the workspace in the cluster (a few minutes the first time)…"
    if ! (cd "$folder" && bash "${DEVZONE_WORKSPACE_SH:-$script}" start); then
        echo "✖ Workspace not started. The folder is ready: only the start remains (cd $folder && devzone workspace start)" >&2
        return 1
    fi
    echo "Next: cd $folder && make shell (the pod)"
}
