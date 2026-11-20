#!/usr/bin/env bats
# Tests of the host Docker (fakes in $BATS_TEST_TMPDIR/bin).

setup() {
    load commun
    export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp/bats}"
    kube_isole
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export DEVZONE_INSTANCE="${DEVZONE_INSTANCE:-devzone}"
    export ETAT="$BATS_TEST_TMPDIR/state"
    : >"$ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# --- kube_reachable_from_container ---------------------------------------
# docker: no kind node by default; FAKE_NODE=<name> to simulate one
setup_docker_node() {
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    "ps --filter label=io.x-k8s.kind.role=control-plane --filter publish=6443"*) [ -z "${FAKE_NODE:-}" ] || echo "$FAKE_NODE" ;;
    "inspect "*) echo "kind " ;;
esac
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    : >"$BATS_TEST_TMPDIR/docker.log"
}

setup_kubectl_view() {
    setup_docker_node
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config view"*)
        printf 'cluster127\thttps://127.0.0.1:6443\n'
        printf 'clusterlocalhost\thttps://localhost:6443\n'
        printf 'clusterexample\thttps://example.org:443\n'
        ;;
esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "kube_reachable_from_container : rewrites 127.0.0.1 and localhost" {
    setup_kubectl_view
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    local cfg="$BATS_TEST_TMPDIR/kubeconfig"
    : >"$cfg"
    kube_reachable_from_container "$cfg"
    grep -q "config set-cluster cluster127" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q -- "--server=https://host.docker.internal:6443" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q -- "--tls-server-name=127.0.0.1" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q "config set-cluster clusterlocalhost" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q -- "--tls-server-name=localhost" "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q "set-cluster clusterexample" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kube_reachable_from_container : idempotent" {
    setup_kubectl_view
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    local cfg="$BATS_TEST_TMPDIR/kubeconfig"
    : >"$cfg"
    kube_reachable_from_container "$cfg"
    kube_reachable_from_container "$cfg"
    [ "$(grep -c "config set-cluster" "$BATS_TEST_TMPDIR/kubectl.log")" -eq 4 ]
}

# --- instance suffix -----------------------------------------------------
@test "suffix : DEVZONE_INSTANCE=devzone -> kind-devzone" {
    (
        export DEVZONE_INSTANCE=devzone
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        [ "$CLUSTER_DEDICATED" = "kind-devzone" ]
    )
}

@test "suffix : DEVZONE_INSTANCE=mon-devzone -> kind-devzone-mon-devzone" {
    (
        export DEVZONE_INSTANCE=mon-devzone
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        [ "$CLUSTER_DEDICATED" = "kind-devzone-mon-devzone" ]
    )
}

# --- cluster_choose --------------------------------------------------------
setup_cluster_choisir() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts -o name"*) echo "docker-desktop" ;;
    *"config current-context"*) echo "docker-desktop" ;;
    *"config view"*)
        name=""
        for c in docker-desktop; do
            if [[ "$*" == *\"$c\"* ]]; then name="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo "$name"; fi
        ;;
    *"get --raw /readyz"*)
        if [ "${FAKE_HOST_ANSWERS:-1}" = 1 ]; then exit 0; else exit 1; fi
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    : >"$DEVZONE_KUBE_HOTE"
}

@test "cluster_choose : host answers -> contexte host" {
    setup_cluster_choisir
    export FAKE_HOST_ANSWERS=1
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/state"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop" ]
    )
}

@test "cluster_choose : host ne repond pas -> kind-devzone" {
    setup_cluster_choisir
    export FAKE_HOST_ANSWERS=0
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/state"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose
        [ "$status" -eq 0 ]
        [ "$output" = "kind-devzone" ]
    )
}

@test "cluster_choose : kept choice respected even if the host answers" {
    setup_cluster_choisir
    export FAKE_HOST_ANSWERS=1
    printf 'cluster=docker-desktop-kept\n' >"$BATS_TEST_TMPDIR/state"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/state"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop-kept" ]
    )
}

# --- uninstall ---------------------------------------------------------
@test "uninstall : filter by instance, no kind" {
    export DEVZONE_VOLUMES="mon-devzone"
    export CONFIRMER=oui
    export DEVZONE_DANS_CONTENEUR=non
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    *"ps -aq --filter"*"io.x-k8s.kind.cluster=devzone-mon-devzone"*) echo "KIND_DEVZONE_ID" ;;
    *"ps -aq --filter"*"io.x-k8s.kind.cluster=gitlab-mon-devzone"*) echo "KIND_GITLAB_ID" ;;
    *"ps -aq --filter"*"devzone.instance=mon-devzone"*) echo "LABEL_ID" ;;
    *"ps -aq --filter"*"devzone.instance=other"*) echo "OTHER_ID" ;;
esac
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    : >"$BATS_TEST_TMPDIR/docker.log"
    # kind is usually not installed on the workstation: the uninstall must never
    # call it (the clusters are found by their Docker label)
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
    run bash "$BATS_TEST_DIRNAME/../../manage/scripts/uninstall.sh"
    [ "$status" -eq 0 ]
    grep -q "docker rm -f KIND_DEVZONE_ID" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "docker rm -f KIND_GITLAB_ID" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "docker rm -f LABEL_ID" "$BATS_TEST_TMPDIR/docker.log"
    ! grep -q "docker rm -f OTHER_ID" "$BATS_TEST_TMPDIR/docker.log" || false
    [ ! -s "$BATS_TEST_TMPDIR/kind.log" ]
}

# --- kind wrapper: clusters created by hand reachable -------------------
setup_wrapper() {
    setup_kubectl_view
    cat >"$BATS_TEST_TMPDIR/bin/kind-reel" <<'KIND'
#!/usr/bin/env bash
echo "kind-reel $*" >>"$BATS_TEST_TMPDIR/kind-reel.log"
exit "${FAKE_KIND_CODE:-0}"
KIND
    chmod +x "$BATS_TEST_TMPDIR/bin/kind-reel"
    : >"$BATS_TEST_TMPDIR/kind-reel.log"
    export DEVZONE_KIND_REEL="$BATS_TEST_TMPDIR/bin/kind-reel"
    WRAPPER="$BATS_TEST_DIRNAME/../../.devcontainer/kind-wrapper.sh"
}

@test "kind wrapper : create cluster -> kubeconfig made reachable" {
    setup_wrapper
    export KUBECONFIG="$BATS_TEST_TMPDIR/k1:$BATS_TEST_TMPDIR/k2"
    run bash "$WRAPPER" create cluster --name trial
    [ "$status" -eq 0 ]
    grep -q "kind-reel create cluster --name trial" "$BATS_TEST_TMPDIR/kind-reel.log"
    grep -q -- "--server=https://host.docker.internal:6443" "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "kind wrapper : --kubeconfig respected" {
    setup_wrapper
    run bash "$WRAPPER" export kubeconfig --name trial --kubeconfig "$BATS_TEST_TMPDIR/other"
    [ "$status" -eq 0 ]
    grep -q "config set-cluster" "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "kind wrapper : other subcommand -> nothing rewritten" {
    setup_wrapper
    run bash "$WRAPPER" get clusters
    [ "$status" -eq 0 ]
    ! grep -q "set-cluster" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind wrapper : kind failure passed on, nothing rewritten" {
    setup_wrapper
    export FAKE_KIND_CODE=3
    run bash "$WRAPPER" create cluster --name trial
    [ "$status" -eq 3 ]
    ! grep -q "set-cluster" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "uninstall in the container: no Docker action on the workstation" {
    # docker talks to the host Docker there: the volumes seen would be the workstation's
    export CONFIRMER=oui
    export DEVZONE_DANS_CONTENEUR=oui
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    *"ps -aq"*) echo "UN_CONTENEUR" ;;
    *"volume ls"*) echo "devzone-gh" ;;
esac
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    : >"$BATS_TEST_TMPDIR/docker.log"
    run bash "$BATS_TEST_DIRNAME/../../manage/scripts/uninstall.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"make desinstaller on your machine"* ]] || false
    ! grep -qE "docker (rm|rmi|volume rm|network rm)" "$BATS_TEST_TMPDIR/docker.log" || false
}


@test "cluster_prepare : kind create fails once -> deleted then recreated" {
    setup_kubectl_view
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$*" in
    "get clusters") exit 0 ;;
    create*)
        # first attempt fails, the next one succeeds
        if [ -f "$BATS_TEST_TMPDIR/done_marker" ]; then exit 0; fi
        : >"$BATS_TEST_TMPDIR/done_marker"; exit 1 ;;
esac
exit 0
KIND
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    run cluster_prepare kind-devzone
    [ "$status" -eq 0 ]
    [ "$(grep -c '^kind create cluster' "$BATS_TEST_TMPDIR/kind.log")" -eq 2 ]
    grep -q "^kind delete cluster --name devzone" "$BATS_TEST_TMPDIR/kind.log"
}

@test "kube_reachable_from_container : kind node found -> network joined, node address" {
    setup_kubectl_view
    export FAKE_NODE=trial-control-plane
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    kube_reachable_from_container "$BATS_TEST_TMPDIR/kubeconfig"
    grep -q -- "--server=https://trial-control-plane:6443" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q "docker network connect kind" "$BATS_TEST_TMPDIR/docker.log"
    ! grep -q -- "--tls-server-name" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

