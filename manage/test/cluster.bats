#!/usr/bin/env bats
# Cluster de devzone (cluster.sh) : cluster_est_local, cluster_candidats,
# cluster_menu, cluster_choisir. Faux kubectl et kind dans $BATS_TEST_TMPDIR/bin,
# aucun appel réseau, HOME et DEVZONE_ETAT sous $BATS_TEST_TMPDIR.

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    export DEVZONE_INSTANCE=devzone
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_KUBE_HOTE"
    : >"$DEVZONE_ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# kubectl factice : get-contexts lit hote.contexts, config view retourne
# une paire serveur par contexte (wildcard), get --raw /readyz répond sauf
# FAUX_INJOIGNABLE.
faux_kubectl() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts -o name"*)
        cat "$BATS_TEST_TMPDIR/hote.contexts" 2>/dev/null || true
        ;;
    *"config view"*)
        nom=""
        for c in $(cat "$BATS_TEST_TMPDIR/hote.contexts" 2>/dev/null); do
            if [[ "$*" == *\"$c\"* ]]; then nom="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then
            case "$nom" in
                docker-desktop) echo "https://127.0.0.1:6443" ;;
                cluster-prod) echo "https://example.org:6443" ;;
                kind-devzone) echo "https://127.0.0.1:6443" ;;
                *) echo "https://127.0.0.1:6443" ;;
            esac
        else
            echo "$nom"
        fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in
            *"--context ${FAUX_INJOIGNABLE:-aucun} "*) exit 1 ;;
        esac
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

# kind factice : get clusters vide
faux_kind() {
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
}

@test "cluster_est_local : kind dédié est local" {
    faux_kubectl
    faux_kind
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local kind-devzone
        [ "$status" -eq 0 ]
    ) || false
}

@test "cluster_est_local : hôte 127.0.0.1 est local" {
    faux_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local docker-desktop
        [ "$status" -eq 0 ]
    ) || false
}

@test "cluster_est_local : hôte localhost est local" {
    faux_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'docker-desktop\thttps://localhost:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local docker-desktop
        [ "$status" -eq 0 ]
    ) || false
}

@test "cluster_est_local : hôte distant n'est pas local" {
    faux_kubectl
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local cluster-prod
        [ "$status" -ne 0 ]
    ) || false
}

@test "cluster_est_local : contexte inconnu est local (indéterminable)" {
    faux_kubectl
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local inconnu
        [ "$status" -eq 0 ]
    )
}

@test "cluster_candidats : ordre locaux, kind dédié, distants" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'docker-desktop\ncluster-prod\nkind-devzone\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\ncluster-prod\thttps://example.org:6443\nkind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_candidats
        [ "$status" -eq 0 ] || false
        [ "${lines[0]}" = "docker-desktop" ] || false
        [ "${lines[1]}" = "kind-devzone" ] || false
        [ "${lines[2]}" = "cluster-prod" ] || false
    )
}

@test "cluster_candidats : pas de hote.config → seulement kind dédié" {
    faux_kubectl
    faux_kind
    rm -f "$BATS_TEST_TMPDIR/hote.config"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_candidats
        [ "$status" -eq 0 ]
        [ "$output" = "kind-devzone" ]
    ) || false
}

@test "cluster_menu : marque « distant » et Entrée = premier local" {
    set +e
    faux_kubectl
    (
        export DEVZONE_INTERACTIF=1
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        printf 'docker-desktop\ncluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_menu <<<""
        [ "$status" -eq 0 ] || false
        [[ "$output" == *"cluster local"* ]] || false
        [[ "$output" == *"cluster distant"* ]] || false
        [ "$output" = "docker-desktop" ] || false
    )
}

@test "cluster_choisir : défaut sans état → local (kind dédié)" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir
        [ "$status" -eq 0 ]
        [ "$output" = "kind-devzone" ]
    ) || false
}

@test "cluster_choisir : contexte local explicite accepté" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir docker-desktop
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop" ]
    ) || false
}

@test "cluster_choisir : contexte distant explicite refusé hors terminal" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod </dev/null
        [ "$status" -eq 2 ]
        [[ "$output" == *"cluster distant refusé"* ]] || false
    ) || false
}

@test "cluster_choisir : contexte distant accepté avec DEVZONE_CLUSTER_DISTANT" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        export DEVZONE_CLUSTER_DISTANT=1
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod </dev/null
        [ "$status" -eq 0 ]
        [ "$output" = "cluster-prod" ]
    ) || false
}

@test "cluster_choisir : contexte inconnu refusé" {
    faux_kubectl
    faux_kind
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir inconnu </dev/null
        [ "$status" -eq 2 ]
        [[ "$output" == *"cluster inconnu ou injoignable"* ]] || false
    ) || false
}

@test "cluster_choisir : choix gardé dans l'état retourné tel quel" {
    faux_kubectl
    faux_kind
    printf 'cluster=mon-choix\n' >"$BATS_TEST_TMPDIR/etat"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir
        [ "$status" -eq 0 ]
        [ "$output" = "mon-choix" ]
    ) || false
}
