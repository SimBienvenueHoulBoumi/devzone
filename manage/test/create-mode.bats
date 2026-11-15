#!/usr/bin/env bats
# Mode at creation (#497): create_mode_choose and create_mode_write in
# manage/scripts/create-mode.sh. Fake kubectl and helm under
# $BATS_TEST_TMPDIR/bin, PATH isolated from the real tools. No real cluster.

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
    *"jsonpath"*) echo https://127.0.0.1:6443 ;;
esac
KUBECTL
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_LOG"
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    export PATH="$T/bin:/usr/bin:/bin"
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

@test "no option, cluster unreachable: docker, notice with the reason and migrate" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    choose ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ Kubernetes not reachable: cluster devzone unreachable"* ]] || false
    [[ "$output" == *"later: devzone workspace migrate"* ]] || false
    [[ "$output" == *"mode=docker"* ]] || false
}

@test "no option, helm missing: docker, reason helm missing" {
    rm "$T/bin/helm"
    choose ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ Kubernetes not reachable: helm missing"* ]] || false
    [[ "$output" == *"mode=docker"* ]] || false
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

@test "--docker: docker, cluster not asked" {
    choose docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker workstation (--docker)"* ]] || false
    [[ "$output" == *"mode=docker"* ]] || false
    [ ! -s "$FAKE_LOG" ]
}

@test "create_mode_write: new folder gets workspace=kubernetes" {
    run bash -c '. "$1"; create_mode_write "$2" kubernetes' _ "$CM" "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/folder/.devzone.modules")" = "workspace=kubernetes" ]
}

@test "create_mode_write: earlier workspace= replaced, other lines kept" {
    printf 'argocd=on\nworkspace=docker\nports=auto\n' >"$T/folder/.devzone.modules"
    run bash -c '. "$1"; create_mode_write "$2" kubernetes' _ "$CM" "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/folder/.devzone.modules")" = "$(printf 'argocd=on\nports=auto\nworkspace=kubernetes')" ]
    [ ! -e "$T/folder/.devzone.modules.tmp" ]
}
