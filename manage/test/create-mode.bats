#!/usr/bin/env bats
# Mode at creation (#497): create_mode_choose and create_mode_write in
# manage/scripts/create-mode.sh. Fake kubectl and helm under
# $BATS_TEST_TMPDIR/bin; PATH holds only those and a folder of links to the
# tools the scripts call (outils_isoles), never /usr/bin or /bin. No real cluster.

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CM="$RACINE/manage/scripts/create-mode.sh"
    T="$BATS_TEST_TMPDIR"
    FAKE_LOG="$T/tools.log"
    export FAKE_LOG
    mkdir -p "$T/bin" "$T/folder"
    cat >"$T/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
    *"get-contexts"*) [ "${FAKE_CONTEXTS-devzone}" = devzone ] && echo devzone ;;
    *"cluster-info"*) [ "${FAKE_KUBE_CLUSTER_INFO:-ok}" = ok ] ;;
    *"current-context"*) echo kind-poste ;;
    *"clusters[0].cluster.server"*) echo https://127.0.0.1:6443 ;;
    *"get application"*) [ "${FAKE_ARGO_APP:-absent}" = present ] ;;
esac
KUBECTL
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_LOG"
case "$1" in
    status) [ "${FAKE_HELM_RELEASE:-absent}" = present ] ;;
esac
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    outils_isoles "$T/outils"
    export PATH="$T/bin:$T/outils"
    : >"$FAKE_LOG"
    unset FAKE_KUBE_CLUSTER_INFO FAKE_CONTEXTS
}

# Chooses the mode for the option ("" for none), prints the mode set.
choose() {
    run bash -c '. "$1"; create_mode_choose "$2" && echo "mode=$CREATE_MODE"' _ "$CM" "$1"
}

@test "no option, cluster ready: kubernetes, notice with the context" {
    choose ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Kubernetes ready (devzone): workspace in the cluster"* ]] || false
    [[ "$output" == *"mode=kubernetes"* ]] || false
}

@test "no option, cluster unreachable: status 1, the ways to get a cluster, no mode set" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    choose ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Kubernetes not reachable: cluster devzone unreachable"* ]] || false
    [[ "$output" == *"Nothing created"* ]] || false
    [[ "$output" == *"kubectl config use-context"* ]] || false
    [[ "$output" == *"minikube start -p devzone"* ]] || false
    [[ "$output" != *"mode="* ]] || false
    [ ! -e "$T/folder/.devzone.modules" ]
}

@test "no option, cluster unreachable: the commands are displayed, never run" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    choose ""
    [ "$status" -eq 1 ]
    [[ "$(cat "$FAKE_LOG")" != *"minikube"* ]] || false
    [[ "$(cat "$FAKE_LOG")" != *"update-kubeconfig"* ]] || false
}

@test "no option, helm missing: status 1, reason helm missing" {
    rm "$T/bin/helm"
    choose ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Kubernetes not reachable: helm missing"* ]] || false
    [[ "$output" != *"mode="* ]] || false
}

@test "--kubernetes, cluster unreachable: status 1, error notice, nothing written" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    choose kubernetes
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Kubernetes not reachable: cluster devzone unreachable"* ]] || false
    [[ "$output" == *"Nothing created"* ]] || false
    [[ "$output" != *"mode="* ]] || false
    [ ! -e "$T/folder/.devzone.modules" ]
}

@test "--kubernetes, cluster ready: kubernetes" {
    choose kubernetes
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=kubernetes"* ]] || false
}

@test "create_mode_write: new folder gets workspace=kubernetes" {
    run bash -c '. "$1"; create_mode_write "$2" kubernetes' _ "$CM" "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/folder/.devzone.modules")" = "workspace=kubernetes" ]
}

@test "kubernetes chosen, helm release already installed: notice, mode kept" {
    FAKE_HELM_RELEASE=present
    export FAKE_HELM_RELEASE
    choose ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"ℹ a devzone workspace already runs in this cluster"* ]] || false
    [[ "$output" == *"mode=kubernetes"* ]] || false
    [[ "$(cat "$FAKE_LOG")" == *"helm status devzone-workspace --namespace devzone-workspace --kube-context devzone"* ]] || false
}

@test "kubernetes chosen, Argo CD Application already there: notice" {
    FAKE_ARGO_APP=present
    export FAKE_ARGO_APP
    choose kubernetes
    [ "$status" -eq 0 ]
    [[ "$output" == *"ℹ a devzone workspace already runs in this cluster"* ]] || false
    [[ "$output" == *"mode=kubernetes"* ]] || false
}

@test "kubernetes chosen, nothing installed: no notice" {
    choose ""
    [ "$status" -eq 0 ]
    [[ "$output" != *"already runs"* ]] || false
}

@test "create_mode_write: earlier workspace= replaced, other lines kept" {
    printf 'argocd=on\nworkspace=docker\nports=auto\n' >"$T/folder/.devzone.modules"
    run bash -c '. "$1"; create_mode_write "$2" kubernetes' _ "$CM" "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/folder/.devzone.modules")" = "$(printf 'argocd=on\nports=auto\nworkspace=kubernetes')" ]
    [ ! -e "$T/folder/.devzone.modules.tmp" ]
}
