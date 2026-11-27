#!/usr/bin/env bash
# Workspace mode at creation (#497): a new devzone is a Kubernetes workspace,
# so the cluster must answer. Without a cluster there is no fallback (#671):
# creation stops and lists the ways to get a cluster. The Docker workstation is
# retired (#735). Sourced by manage/devzone (creer): create_mode_choose runs
# before any file is copied (so --kubernetes without a cluster creates
# nothing), create_mode_write once the folder exists.
# Sourced only: no code at file level. Compatible with bash 3.2 (macOS).
# shellcheck disable=SC2034 # CREATE_MODE is read by manage/devzone (creer)

# Context shown to the user: devzone if declared, otherwise the current one.
kube_context() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        echo devzone
    else
        kubectl config current-context 2>/dev/null || echo none
    fi
}

# Prints, on stderr, how to get a cluster: devzone only displays the commands,
# it never runs them and no cloud credential goes through it.
create_mode_no_cluster() {
    cat >&2 <<EOF
✖ Kubernetes not reachable: $1. Nothing created.
  devzone runs in a Kubernetes cluster. Pick one, then run the same command again:
  - a remote cluster (AWS, GCP, Azure, other): add its context to your kubeconfig, then select it
      aws eks update-kubeconfig --name <cluster>
      gcloud container clusters get-credentials <cluster>
      az aks get-credentials --name <cluster> --resource-group <group>
      kubectl config use-context <context>
  - a local cluster: Docker Desktop (Settings > Kubernetes > Enable Kubernetes), or minikube
      minikube start -p devzone
EOF
}

# Chooses the mode from the option (kubernetes or empty) and sets CREATE_MODE
# to kubernetes, with one line of notice. Returns 1, nothing set on disk, when
# the cluster does not answer.
create_mode_choose() {
    local option="$1" reason
    if reason="$("${DEVZONE_HOST_BIN:?devzone: Go program not found (DEVZONE_HOST_BIN), run it through manage/devzone}" kube-ready)"; then
        CREATE_MODE=kubernetes
        echo "✔ Kubernetes ready ($(kube_context)): workspace in the cluster"
        create_mode_existing
        return 0
    fi
    # No option, in a terminal: a menu (remote cluster, minikube) instead of a
    # failure (#653); the choice is accepted only if the cluster then answers.
    # The menu is the Go program's (#884), found through DEVZONE_HOST_BIN; without
    # it no menu is offered (false), and the failure below lists the ways to get a cluster
    if [ -z "$option" ] && "${DEVZONE_HOST_BIN:-false}" cluster-offer && reason="$("${DEVZONE_HOST_BIN:?devzone: Go program not found (DEVZONE_HOST_BIN), run it through manage/devzone}" kube-ready)"; then
        CREATE_MODE=kubernetes
        echo "✔ Kubernetes ready ($(kube_context)): workspace in the cluster"
        create_mode_existing
        return 0
    fi
    create_mode_no_cluster "$reason"
    return 1
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
# replaces the script (tests); DEVZONE_NO_START only prints the command.
create_mode_start() {
    local folder="$1" script="$2"
    if [ -n "${DEVZONE_NO_START:-}" ]; then
        echo "To start the workspace: cd $folder && devzone workspace start"
        return 0
    fi
    echo "▶ Starting the workspace in the cluster (a few minutes the first time)…"
    if ! (cd "$folder" && bash "${DEVZONE_WORKSPACE_SH:-$script}" start); then
        echo "✖ Workspace not started. The folder is ready: only the start remains (cd $folder && devzone workspace start)" >&2
        return 1
    fi
    echo "Next: cd $folder && devzone workspace shell (the pod)"
}
