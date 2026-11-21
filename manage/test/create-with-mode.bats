#!/usr/bin/env bats
# Creation of a devzone with its mode (#497): devzone <folder> [--kubernetes|--docker].
# Fake kubectl, helm, docker and workspace script under $BATS_TEST_TMPDIR;
# no real cluster, Docker, make or workspace start.

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    FAKE_LOG="$T/tools.log"
    export FAKE_LOG
    mkdir -p "$T/bin" "$T/work"
    cat >"$T/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
    *"get-contexts"*) echo devzone ;;
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
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
DOCKER
    cat >"$T/ws.sh" <<'WS'
#!/usr/bin/env bash
echo "workspace $* in $(basename "$PWD")" >>"$FAKE_LOG"
WS
    printf '#!/usr/bin/env bash\necho "workspace failed" >>"$FAKE_LOG"\nexit 1\n' >"$T/ws-failed.sh"
    chmod +x "$T/bin/kubectl" "$T/bin/helm" "$T/bin/docker" "$T/ws.sh" "$T/ws-failed.sh"
    export PATH="$T/bin:$PATH"
    export DEVZONE_WORKSPACE_SH="$T/ws.sh"
    export DEVZONE_NO_START=1
    : >"$FAKE_LOG"
    unset FAKE_KUBE_CLUSTER_INFO
    cd "$T/work" || return 1
}

@test "cluster ready, no option: kubernetes recorded, notice, start only printed" {
    run bash "$CLI" mon --gitops none
    [ "$status" -eq 0 ]
    [ "$(cat mon/.devzone.modules)" = "workspace=kubernetes" ]
    [[ "$output" == *"✔ Kubernetes ready (devzone): workspace in the cluster"* ]] || false
    [[ "$output" == *"To start the workspace: cd "*"devzone workspace start"* ]] || false
    [[ "$(cat "$FAKE_LOG")" != *"workspace start"* ]] || false
}

@test "cluster ready, no option, no DEVZONE_NO_START: workspace started in the folder, no Docker" {
    unset DEVZONE_NO_START
    run bash "$CLI" mon --gitops none
    [ "$status" -eq 0 ]
    [[ "$(cat "$FAKE_LOG")" == *"workspace start in mon"* ]] || false
    [[ "$(cat "$FAKE_LOG")" != *"docker"* ]] || false
    [[ "$output" == *"Next: cd "*"make shell (the pod)"* ]] || false
}

@test "cluster unreachable, no option: status 1, folder not created, ways to get a cluster" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    run bash "$CLI" mon --gitops none
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Kubernetes not reachable: cluster devzone unreachable"*"Nothing created"* ]] || false
    [[ "$output" == *"minikube start -p devzone"* ]] || false
    [ ! -e mon ]
}

@test "cluster unreachable, --docker: docker recorded with the deprecation notice" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    run bash "$CLI" mon --docker --gitops none
    [ "$status" -eq 0 ]
    [ "$(cat mon/.devzone.modules)" = "workspace=docker" ]
    [[ "$output" == *"is deprecated and will be removed"* ]] || false
    [[ "$output" == *"cd "*"make up"* ]] || false
}

@test "--kubernetes, cluster unreachable: status 1, folder not created" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    run bash "$CLI" mon --kubernetes --gitops none
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Kubernetes not reachable"*"Nothing created"* ]] || false
    [ ! -e mon ]
}

@test "--docker, cluster ready: docker recorded, cluster not asked" {
    run bash "$CLI" mon --docker --gitops none
    [ "$status" -eq 0 ]
    [ "$(cat mon/.devzone.modules)" = "workspace=docker" ]
    [[ "$output" == *"Docker workstation (--docker) is deprecated"* ]] || false
    [[ "$(cat "$FAKE_LOG")" != *"cluster-info"* ]] || false
}

@test "--kubernetes and --docker together: usage error, folder not created" {
    run bash "$CLI" mon --kubernetes --docker --gitops none
    [ "$status" -eq 1 ]
    [[ "$output" == *"choose one"* ]] || false
    [ ! -e mon ]
}

@test "--kubernetes, start fails: status 1, folder kept, the start to redo named" {
    unset DEVZONE_NO_START
    export DEVZONE_WORKSPACE_SH="$T/ws-failed.sh"
    run bash "$CLI" mon --kubernetes --gitops none
    [ "$status" -eq 1 ]
    [ -f mon/Makefile ]
    [[ "$output" == *"Workspace not started"*"devzone workspace start"* ]] || false
}

@test "workspace already in the cluster: notice, creation goes on in kubernetes mode" {
    FAKE_HELM_RELEASE=present
    export FAKE_HELM_RELEASE
    run bash "$CLI" mon --gitops none
    [ "$status" -eq 0 ]
    [ "$(cat mon/.devzone.modules)" = "workspace=kubernetes" ]
    [ -f mon/Makefile ]
    [[ "$output" == *"ℹ a devzone workspace already runs in this cluster: this folder drives it too"* ]] || false
    [[ "$output" == *"To start the workspace"* ]] || false
}
