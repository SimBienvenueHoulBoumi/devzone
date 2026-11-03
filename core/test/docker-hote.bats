#!/usr/bin/env bats
# Tests du Docker de l'hôte (doublures dans $BATS_TEST_TMPDIR/bin).

setup() {
    export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp/bats}"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export DEVZONE_INSTANCE="${DEVZONE_INSTANCE:-devzone}"
    export ETAT="$BATS_TEST_TMPDIR/etat"
    : >"$ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# --- kube_joignable_depuis_conteneur ---------------------------------------
setup_kubectl_view() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config view"*)
        printf 'cluster127\thttps://127.0.0.1:6443\n'
        printf 'clusterlocalhost\thttps://localhost:6443\n'
        printf 'clusterexemple\thttps://example.org:443\n'
        ;;
esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "kube_joignable_depuis_conteneur : reecrit 127.0.0.1 et localhost" {
    setup_kubectl_view
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    local cfg="$BATS_TEST_TMPDIR/kubeconfig"
    : >"$cfg"
    kube_joignable_depuis_conteneur "$cfg"
    grep -q "config set-cluster cluster127" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q -- "--server=https://host.docker.internal:6443" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q -- "--tls-server-name=127.0.0.1" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q "config set-cluster clusterlocalhost" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q -- "--tls-server-name=localhost" "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q "set-cluster clusterexemple" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kube_joignable_depuis_conteneur : idempotente" {
    setup_kubectl_view
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    local cfg="$BATS_TEST_TMPDIR/kubeconfig"
    : >"$cfg"
    kube_joignable_depuis_conteneur "$cfg"
    kube_joignable_depuis_conteneur "$cfg"
    [ "$(grep -c "config set-cluster" "$BATS_TEST_TMPDIR/kubectl.log")" -eq 4 ]
}

# --- suffixe d'instance -----------------------------------------------------
@test "suffixe : DEVZONE_INSTANCE=devzone -> kind-devzone" {
    (
        export DEVZONE_INSTANCE=devzone
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        [ "$CLUSTER_DEDIE" = "kind-devzone" ]
    )
}

@test "suffixe : DEVZONE_INSTANCE=mon-devzone -> kind-devzone-mon-devzone" {
    (
        export DEVZONE_INSTANCE=mon-devzone
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        [ "$CLUSTER_DEDIE" = "kind-devzone-mon-devzone" ]
    )
}

# --- cluster_choisir --------------------------------------------------------
setup_cluster_choisir() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts -o name"*) echo "docker-desktop" ;;
    *"config current-context"*) echo "docker-desktop" ;;
    *"get --raw /readyz"*)
        if [ "${FAUX_HOTE_REPOND:-1}" = 1 ]; then exit 0; else exit 1; fi
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    : >"$DEVZONE_KUBE_HOTE"
}

@test "cluster_choisir : hote repond -> contexte hote" {
    setup_cluster_choisir
    export FAUX_HOTE_REPOND=1
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop" ]
    )
}

@test "cluster_choisir : hote ne repond pas -> kind-devzone" {
    setup_cluster_choisir
    export FAUX_HOTE_REPOND=0
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir
        [ "$status" -eq 0 ]
        [ "$output" = "kind-devzone" ]
    )
}

@test "cluster_choisir : choix garde respecte meme si hote repond" {
    setup_cluster_choisir
    export FAUX_HOTE_REPOND=1
    printf 'cluster=docker-desktop-garde\n' >"$BATS_TEST_TMPDIR/etat"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop-garde" ]
    )
}

# --- desinstallation ---------------------------------------------------------
@test "desinstallation : filtre par instance, pas de kind" {
    export DEVZONE_VOLUMES="mon-devzone"
    export CONFIRMER=oui
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    *"ps -aq --filter"*"io.x-k8s.kind.cluster=devzone-mon-devzone"*) echo "KIND_DEVZONE_ID" ;;
    *"ps -aq --filter"*"io.x-k8s.kind.cluster=gitlab-mon-devzone"*) echo "KIND_GITLAB_ID" ;;
    *"ps -aq --filter"*"devzone.instance=mon-devzone"*) echo "ETIQ_ID" ;;
    *"ps -aq --filter"*"devzone.instance=autre"*) echo "AUTRE_ID" ;;
esac
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    : >"$BATS_TEST_TMPDIR/docker.log"
    # kind n'est en général pas installé sur le poste : la désinstallation ne
    # doit jamais l'appeler (les clusters se retrouvent par étiquette Docker)
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
    run bash "$BATS_TEST_DIRNAME/../../core/scripts/desinstaller.sh"
    [ "$status" -eq 0 ]
    grep -q "docker rm -f KIND_DEVZONE_ID" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "docker rm -f KIND_GITLAB_ID" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "docker rm -f ETIQ_ID" "$BATS_TEST_TMPDIR/docker.log"
    ! grep -q "docker rm -f AUTRE_ID" "$BATS_TEST_TMPDIR/docker.log" || false
    [ ! -s "$BATS_TEST_TMPDIR/kind.log" ]
}
