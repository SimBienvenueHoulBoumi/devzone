#!/usr/bin/env bats
# Cluster de devzone (cluster.sh) : cluster_est_local, cluster_candidats,
# cluster_menu, cluster_choisir. Faux kubectl et kind dans $BATS_TEST_TMPDIR/bin,
# aucun appel réseau, HOME et DEVZONE_ETAT sous $BATS_TEST_TMPDIR.

setup() {
    load commun
    kube_isole
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
                kind-gitlab) echo "https://gitlab-control-plane:6443" ;;
                cluster-ipv6) echo "https://[::1]:6443" ;;
                sans-serveur) echo "" ;;
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

# kubectl factice limite au contexte courant : lit et écrit
# $HOME/.kube/config, comme les commandes `kubectl config` utilisées par
# kind_creer_sans_basculer. Les autres appels sont neutres.
faux_kubectl_contexte() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
fichier="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
case "$*" in
    "config current-context")
        sed -n 's/^current-context:[[:space:]]*//p' "$fichier" 2>/dev/null | head -1
        ;;
    "config use-context "*)
        nouveau="${3:-}"
        { grep -v '^current-context:' "$fichier" 2>/dev/null || true; printf 'current-context: %s\n' "$nouveau"; } >"$fichier.tmp"
        mv "$fichier.tmp" "$fichier"
        ;;
    "config unset current-context")
        { grep -v '^current-context:' "$fichier" 2>/dev/null || true; } >"$fichier.tmp"
        mv "$fichier.tmp" "$fichier"
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

# kind factice : get clusters vide ; create écrit le contexte kind-<nom> comme
# le vrai, puis échoue avec le code 1 si FAUX_KIND_ECHEC=1.
faux_kind_contexte() {
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") exit 0 ;;
    "create cluster")
        nom=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --name) nom="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        mkdir -p "$HOME/.kube"
        printf 'current-context: kind-%s\n' "$nom" >"$HOME/.kube/config"
        if [ "${FAUX_KIND_ECHEC:-0}" = 1 ]; then exit 1; fi
        exit 0
        ;;
esac
exit 0
KIND
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

@test "cluster_est_local : contexte inconnu est distant" {
    faux_kubectl
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local inconnu
        [ "$status" -ne 0 ] || false
    ) || false
}

@test "cluster_est_local : sans serveur est distant" {
    faux_kubectl
    printf 'sans-serveur\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local sans-serveur
        [ "$status" -ne 0 ] || false
    ) || false
}

@test "cluster_est_local : kind-gitlab (gitlab-control-plane) est local" {
    faux_kubectl
    printf 'kind-gitlab\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local kind-gitlab
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_est_local : docker-desktop local par le nom" {
    faux_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local docker-desktop
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_est_local : kind-x local par le nom" {
    faux_kubectl
    printf 'kind-x\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local kind-x
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_est_local : serveur IPv6 bracket local" {
    faux_kubectl
    printf 'cluster-ipv6\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_est_local cluster-ipv6
        [ "$status" -eq 0 ] || false
    ) || false
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
        export DEVZONE_CLUSTER_DISTANT=cluster-prod
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod </dev/null
        [ "$status" -eq 0 ] || false
        [ "$output" = "cluster-prod" ] || false
    ) || false
}

@test "cluster_choisir : DEVZONE_CLUSTER_DISTANT autre refusé" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        export DEVZONE_CLUSTER_DISTANT=autre
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod </dev/null
        [ "$status" -eq 2 ] || false
        [[ "$output" == *"cluster distant refusé"* ]] || false
    ) || false
}

@test "cluster_choisir : --confirmer exact accepté hors terminal" {
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
        run cluster_choisir cluster-prod --confirmer cluster-prod </dev/null
        [ "$status" -eq 0 ] || false
        [ "$output" = "cluster-prod" ] || false
    ) || false
}

@test "cluster_choisir : --confirmer autre refusé" {
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
        run cluster_choisir cluster-prod --confirmer autre </dev/null
        [ "$status" -eq 2 ] || false
        [[ "$output" == *"cluster distant refusé"* ]] || false
    ) || false
}

@test "cluster_choisir : --confirmer sans valeur refusé" {
    faux_kubectl
    faux_kind
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod --confirmer </dev/null
        [ "$status" -eq 2 ] || false
        [[ "$output" == *"--confirmer attend un contexte"* ]] || false
    ) || false
}

@test "cluster_choisir : confirmation saisie exacte acceptée" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INTERACTIF=1
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod <<<"cluster-prod"
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_choisir : confirmation o refusé" {
    faux_kubectl
    faux_kind
    FAUX_INJOIGNABLE=aucun
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"
    (
        export DEVZONE_INTERACTIF=1
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choisir cluster-prod <<<"o"
        [ "$status" -eq 2 ] || false
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

@test "kind_creer_sans_basculer : succès, contexte docker-desktop restauré" {
    faux_kubectl_contexte
    faux_kind_contexte
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    (
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        kind_creer_sans_basculer --name devzone --wait 120s
    ) || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
    grep -qx 'kind create cluster --name devzone --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    grep -qx 'kubectl config use-context docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind_creer_sans_basculer : échec sous set -e, contexte restauré et code 1 rendu" {
    faux_kubectl_contexte
    faux_kind_contexte
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    FAUX_KIND_ECHEC=1 run bash -c '
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$1/etat"
        export DEVZONE_KUBE_HOTE="$1/hote.config"
        source "$2"
        kind_creer_sans_basculer --name devzone --wait 120s
    ' _ "$BATS_TEST_TMPDIR" "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    [ "$status" -eq 1 ] || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
    grep -qx 'kubectl config use-context docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind_creer_sans_basculer : aucun contexte avant, unset appelé" {
    faux_kubectl_contexte
    faux_kind_contexte
    mkdir -p "$HOME/.kube"
    : >"$HOME/.kube/config"
    (
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        kind_creer_sans_basculer --name devzone --wait 120s
    ) || false
    grep -qx 'kubectl config unset current-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'config use-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -z "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" ] || false
}

@test "cluster_preparer : le cluster kind est créé par kind_creer_sans_basculer" {
    faux_kubectl_contexte
    faux_kind_contexte
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    (
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        cluster_preparer kind-devzone
    ) || false
    grep -qx 'kind create cluster --name devzone --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
}
