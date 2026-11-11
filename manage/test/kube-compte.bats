#!/usr/bin/env bats
# Compte Kubernetes limité (#430) : compte_poser, compte_autoriser,
# compte_retirer, compte_jeton et l'interface jeton de kube-compte.sh. Faux
# kubectl dans $BATS_TEST_TMPDIR/bin, qui journalise et tient l'état des
# commandes `config set-*` dans $HOME/.kube/config : aucun cluster touché,
# jamais le kubeconfig du poste.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    KOMPTE="$BATS_TEST_DIRNAME/../../.devcontainer/kube-compte.sh"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_ETAT"
    # hote.config existe et liste docker-desktop (kubeconfig de l'hôte)
    : >"$DEVZONE_KUBE_HOTE"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
CONFIG="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
apres() {
    local cible="$1" a prev=""
    shift
    for a in "$@"; do
        if [ "$prev" = "$cible" ]; then
            echo "$a"
            return 0
        fi
        prev="$a"
    done
}
case "$*" in
    *"config get-contexts -o name"*) cat "$T/hote.contexts" 2>/dev/null || true ;;
    *"config view"*)
        if [[ "$*" == *'.context.cluster'* ]]; then
            case "$*" in
                *"docker-desktop"*) echo cluster-hote ;;
                *"kind-devzone"*) echo kind-devzone ;;
            esac
        elif [[ "$*" == *'.cluster.server'* ]]; then
            echo "https://127.0.0.1:6443"
        fi
        ;;
    *"config set-cluster"*)
        printf 'cluster: %s %s\n' "$(apres set-cluster "$@")" "$4" >>"$CONFIG" ;;
    *"config set-credentials"*)
        printf 'user: %s %s\n' "$(apres set-credentials "$@")" "$4" >>"$CONFIG" ;;
    *"config set-context"*)
        printf 'context: %s %s %s\n' "$(apres set-context "$@")" "$4" "$5" >>"$CONFIG" ;;
    *"create token"*) echo jeton-de-test ;;
    *"create namespace"*)
        printf 'kind: Namespace\nmetadata:\n  name: %s\n' "$(apres namespace "$@")" ;;
    *"create serviceaccount"*)
        printf 'kind: ServiceAccount\nmetadata:\n  name: %s\n' "$(apres serviceaccount "$@")" ;;
    *"create rolebinding"*)
        printf 'kind: RoleBinding\nmetadata:\n  name: %s\n' "$(apres rolebinding "$@")" ;;
    *"get namespaces -l"*)
        if [ -f "$T/namespaces" ]; then cat "$T/namespaces"; fi
        ;;
    *"apply -f -"*) cat >>"$T/apply.log" ;;
    *"delete rolebinding"*) ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/apply.log"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "compte_poser : namespace devzone-system et ServiceAccount posés par l'administrateur" {
    (
        set -e
        source "$KOMPTE"
        compte_poser docker-desktop
    ) || false
    grep -qF -- "--kubeconfig=$BATS_TEST_TMPDIR/hote.config --context docker-desktop create namespace devzone-system --dry-run=client -o yaml" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qF -- "--context docker-desktop -n devzone-system create serviceaccount devzone-agent --dry-run=client -o yaml" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'kind: ServiceAccount' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "compte_autoriser : RoleBinding devzone-agent vers edit, compte posé d'abord" {
    (
        set -e
        source "$KOMPTE"
        compte_autoriser docker-desktop devzone-postgres
    ) || false
    grep -qF -- "--context docker-desktop -n devzone-postgres create rolebinding devzone-agent --clusterrole=edit --serviceaccount=devzone-system:devzone-agent" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'kind: RoleBinding' "$BATS_TEST_TMPDIR/apply.log" || false
    # Le compte (namespace devzone-system + ServiceAccount) est posé avant
    grep -q 'create namespace devzone-system' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'create serviceaccount devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "compte_retirer : RoleBinding supprimé dans le namespace" {
    (
        set -e
        source "$KOMPTE"
        compte_retirer docker-desktop devzone-postgres
    ) || false
    grep -qF -- "--context docker-desktop -n devzone-postgres delete rolebinding devzone-agent --ignore-not-found" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "compte_jeton : jeton 24 h écrit dans le contexte devzone de ~/.kube/config" {
    (
        set -e
        source "$KOMPTE"
        compte_jeton docker-desktop
    ) || false
    grep -qF -- "--context docker-desktop create token devzone-agent -n devzone-system --duration=24h" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    # User devzone-agent avec le jeton, entrée cluster copiée, contexte devzone
    # sur le même cluster que le contexte de l'hôte
    grep -qx 'user: devzone-agent --token=jeton-de-test' "$HOME/.kube/config" || false
    grep -qx 'cluster: cluster-hote --server=https://127.0.0.1:6443' "$HOME/.kube/config" || false
    grep -qx 'context: devzone --cluster=cluster-hote --user=devzone-agent' "$HOME/.kube/config" || false
}

@test "compte_jeton : cluster kind du conteneur → kubeconfig ~/.kube/config" {
    (
        set -e
        source "$KOMPTE"
        compte_jeton kind-devzone
    ) || false
    grep -qF -- "--kubeconfig=$HOME/.kube/config --context kind-devzone create token devzone-agent" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'context: devzone --cluster=kind-devzone --user=devzone-agent' "$HOME/.kube/config" || false
}

@test "kube-compte.sh jeton : sans cluster des services choisi, rien ne s'exécute" {
    run bash "$KOMPTE" jeton
    [ "$status" -eq 0 ] || false
    [ ! -s "$BATS_TEST_TMPDIR/kubectl.log" ] || false
}

@test "kube-compte.sh jeton : compte posé et jeton renouvelé" {
    printf 'cluster=docker-desktop\n' >"$DEVZONE_ETAT"
    run bash "$KOMPTE" jeton
    [ "$status" -eq 0 ] || false
    grep -q 'create namespace devzone-system' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qF -- "--context docker-desktop create token devzone-agent -n devzone-system --duration=24h" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'user: devzone-agent --token=jeton-de-test' "$HOME/.kube/config" || false
}

@test "kube-compte.sh : sans argument, refus et usage" {
    run bash "$KOMPTE"
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"kube-compte : jeton"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/kubectl.log" ] || false
}

@test "kube-compte.sh jeton : rattrape les namespaces devzone existants (idempotent)" {
    printf 'cluster=docker-desktop\n' >"$DEVZONE_ETAT"
    printf 'namespace/devzone-mysql\nnamespace/devzone-gitlab\n' >"$BATS_TEST_TMPDIR/namespaces"
    run bash "$KOMPTE" jeton
    [ "$status" -eq 0 ] || false
    [ "$(grep -c 'get namespaces -l app.kubernetes.io/managed-by=devzone' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-mysql create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-gitlab create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c 'kind: RoleBinding' "$BATS_TEST_TMPDIR/apply.log")" -eq 2 ] || false
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/apply.log"
    run bash "$KOMPTE" jeton
    [ "$status" -eq 0 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-mysql create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-gitlab create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c 'kind: RoleBinding' "$BATS_TEST_TMPDIR/apply.log")" -eq 2 ] || false
}
