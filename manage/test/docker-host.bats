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
    export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
    : >"$DEVZONE_KUBE_HOST"
}

@test "cluster_choose : host answers -> contexte host" {
    setup_cluster_choisir
    export FAKE_HOST_ANSWERS=1
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/state"
        export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
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
        export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
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
        export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop-kept" ]
    )
}

# --- uninstall ---------------------------------------------------------
@test "uninstall : filter by instance, no kind" {
    export DEVZONE_VOLUMES="mon-devzone"
    export CONFIRMER=yes
    export DEVZONE_IN_CONTAINER=no
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

@test "uninstall in the container: no Docker action on the workstation" {
    # docker talks to the host Docker there: the volumes seen would be the workstation's
    export CONFIRMER=yes
    export DEVZONE_IN_CONTAINER=yes
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
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
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

