#!/usr/bin/env bats
# Tests du Docker de l'hôte (doublures dans $BATS_TEST_TMPDIR/bin).

setup() {
    load commun
    export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp/bats}"
    kube_isole
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export DEVZONE_INSTANCE="${DEVZONE_INSTANCE:-devzone}"
    export ETAT="$BATS_TEST_TMPDIR/etat"
    : >"$ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# --- kube_joignable_depuis_conteneur ---------------------------------------
# docker : aucun nœud kind par défaut ; FAUX_NOEUD=<nom> pour en simuler un
setup_docker_noeud() {
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    "ps --filter label=io.x-k8s.kind.role=control-plane --filter publish=6443"*) [ -z "${FAUX_NOEUD:-}" ] || echo "$FAUX_NOEUD" ;;
    "inspect "*) echo "kind " ;;
esac
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    : >"$BATS_TEST_TMPDIR/docker.log"
}

setup_kubectl_view() {
    setup_docker_noeud
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
    *"config view"*)
        nom=""
        for c in docker-desktop; do
            if [[ "$*" == *\"$c\"* ]]; then nom="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo "$nom"; fi
        ;;
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
    export DEVZONE_DANS_CONTENEUR=non
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
    run bash "$BATS_TEST_DIRNAME/../../manage/scripts/desinstaller.sh"
    [ "$status" -eq 0 ]
    grep -q "docker rm -f KIND_DEVZONE_ID" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "docker rm -f KIND_GITLAB_ID" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "docker rm -f ETIQ_ID" "$BATS_TEST_TMPDIR/docker.log"
    ! grep -q "docker rm -f AUTRE_ID" "$BATS_TEST_TMPDIR/docker.log" || false
    [ ! -s "$BATS_TEST_TMPDIR/kind.log" ]
}

# --- Enveloppe kind : clusters créés à la main joignables -------------------
setup_enveloppe() {
    setup_kubectl_view
    cat >"$BATS_TEST_TMPDIR/bin/kind-reel" <<'KIND'
#!/usr/bin/env bash
echo "kind-reel $*" >>"$BATS_TEST_TMPDIR/kind-reel.log"
exit "${FAUX_KIND_CODE:-0}"
KIND
    chmod +x "$BATS_TEST_TMPDIR/bin/kind-reel"
    : >"$BATS_TEST_TMPDIR/kind-reel.log"
    export DEVZONE_KIND_REEL="$BATS_TEST_TMPDIR/bin/kind-reel"
    ENVELOPPE="$BATS_TEST_DIRNAME/../../.devcontainer/kind-enveloppe.sh"
}

@test "enveloppe kind : create cluster -> kubeconfig rendu joignable" {
    setup_enveloppe
    export KUBECONFIG="$BATS_TEST_TMPDIR/k1:$BATS_TEST_TMPDIR/k2"
    run bash "$ENVELOPPE" create cluster --name essai
    [ "$status" -eq 0 ]
    grep -q "kind-reel create cluster --name essai" "$BATS_TEST_TMPDIR/kind-reel.log"
    grep -q -- "--server=https://host.docker.internal:6443" "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "enveloppe kind : --kubeconfig respecté" {
    setup_enveloppe
    run bash "$ENVELOPPE" export kubeconfig --name essai --kubeconfig "$BATS_TEST_TMPDIR/autre"
    [ "$status" -eq 0 ]
    grep -q "config set-cluster" "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "enveloppe kind : autre sous-commande -> rien n'est réécrit" {
    setup_enveloppe
    run bash "$ENVELOPPE" get clusters
    [ "$status" -eq 0 ]
    ! grep -q "set-cluster" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "enveloppe kind : échec de kind transmis, rien n'est réécrit" {
    setup_enveloppe
    export FAUX_KIND_CODE=3
    run bash "$ENVELOPPE" create cluster --name essai
    [ "$status" -eq 3 ]
    ! grep -q "set-cluster" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "desinstallation dans le conteneur : aucune action Docker sur le poste" {
    # docker y parle au Docker de l'hôte : les volumes vus seraient ceux du poste
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
    run bash "$BATS_TEST_DIRNAME/../../manage/scripts/desinstaller.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"make desinstaller sur ta machine"* ]] || false
    ! grep -qE "docker (rm|rmi|volume rm|network rm)" "$BATS_TEST_TMPDIR/docker.log" || false
}


@test "cluster_preparer : kind create échoue une fois -> supprimé puis recréé" {
    setup_kubectl_view
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$*" in
    "get clusters") exit 0 ;;
    create*)
        # premier essai en échec, le suivant réussit
        if [ -f "$BATS_TEST_TMPDIR/deja" ]; then exit 0; fi
        : >"$BATS_TEST_TMPDIR/deja"; exit 1 ;;
esac
exit 0
KIND
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    run cluster_preparer kind-devzone
    [ "$status" -eq 0 ]
    [ "$(grep -c '^kind create cluster' "$BATS_TEST_TMPDIR/kind.log")" -eq 2 ]
    grep -q "^kind delete cluster --name devzone" "$BATS_TEST_TMPDIR/kind.log"
}

@test "kube_joignable_depuis_conteneur : nœud kind trouvé -> réseau rejoint, adresse du nœud" {
    setup_kubectl_view
    export FAUX_NOEUD=essai-control-plane
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    kube_joignable_depuis_conteneur "$BATS_TEST_TMPDIR/kubeconfig"
    grep -q -- "--server=https://essai-control-plane:6443" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q "docker network connect kind" "$BATS_TEST_TMPDIR/docker.log"
    ! grep -q -- "--tls-server-name" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

