#!/usr/bin/env bats
# Clusters joignables from the container (#291) in the Kubernetes workspace (#517):
# no docker call, kubeconfig untouched. Fake docker and kubectl in $BATS_TEST_TMPDIR/bin.

setup() {
    load commun
    kube_isole
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    LIB="$BATS_TEST_DIRNAME/../../.devcontainer/kube-reachable.sh"
    CFG="$BATS_TEST_TMPDIR/kubeconfig"
    printf 'clusters:\n- cluster:\n    server: https://127.0.0.1:6443\n  name: cluster127\n' >"$CFG"
    # Fake docker: logs every call, fails (a real docker must never be needed here)
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 1
DOCKER
    # Fake kubectl: logs every call, answers config view with the 127.0.0.1 cluster
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config view"*) printf 'cluster127\thttps://127.0.0.1:6443\n' ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "kubernetes workspace: no docker and no kubectl call, kubeconfig kept (#517)" {
    DEVZONE_WORKSPACE=kubernetes run bash -c '. "$1"; kube_joignable_depuis_conteneur "$2"; echo rc=$?' _ "$LIB" "$CFG"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"rc=0"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/docker.log" ] || false
    [ ! -s "$BATS_TEST_TMPDIR/kubectl.log" ] || false
    grep -q "https://127.0.0.1:6443" "$CFG" || false
}

@test "outside the Kubernetes workspace: the cluster address is rewritten (#291)" {
    run bash -c 'unset DEVZONE_WORKSPACE; . "$1"; kube_joignable_depuis_conteneur "$2"' _ "$LIB" "$CFG"
    [ "$status" -eq 0 ] || false
    grep -q -- "--server=https://host.docker.internal:6443" "$BATS_TEST_TMPDIR/kubectl.log" || false
}
