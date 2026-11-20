#!/usr/bin/env bats
# Limited Kubernetes account (#430): account_setup, account_allow,
# account_remove, account_token and the token interface of kube-account.sh. Fake
# kubectl in $BATS_TEST_TMPDIR/bin, which logs and keeps the state of the
# `config set-*` commands in $HOME/.kube/config: no cluster touched, never the
# workstation's kubeconfig.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    KUBE_ACCOUNT="$BATS_TEST_DIRNAME/../../.devcontainer/kube-account.sh"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_ETAT"
    # hote.config exists and lists docker-desktop (host kubeconfig)
    : >"$DEVZONE_KUBE_HOTE"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
CONFIG="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
after() {
    local target="$1" a prev=""
    shift
    for a in "$@"; do
        if [ "$prev" = "$target" ]; then
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
        printf 'cluster: %s %s\n' "$(after set-cluster "$@")" "$4" >>"$CONFIG" ;;
    *"config set-credentials"*)
        printf 'user: %s %s\n' "$(after set-credentials "$@")" "$4" >>"$CONFIG" ;;
    *"config set-context"*)
        printf 'context: %s %s %s\n' "$(after set-context "$@")" "$4" "$5" >>"$CONFIG" ;;
    *"create token"*) echo token-test ;;
    *"create namespace"*)
        printf 'kind: Namespace\nmetadata:\n  name: %s\n' "$(after namespace "$@")" ;;
    *"create serviceaccount"*)
        printf 'kind: ServiceAccount\nmetadata:\n  name: %s\n' "$(after serviceaccount "$@")" ;;
    *"create rolebinding"*)
        printf 'kind: RoleBinding\nmetadata:\n  name: %s\n' "$(after rolebinding "$@")" ;;
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

@test "account_setup : devzone-system namespace and ServiceAccount set by the administrator" {
    (
        set -e
        source "$KUBE_ACCOUNT"
        account_setup docker-desktop
    ) || false
    grep -qF -- "--kubeconfig=$BATS_TEST_TMPDIR/hote.config --context docker-desktop create namespace devzone-system --dry-run=client -o yaml" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qF -- "--context docker-desktop -n devzone-system create serviceaccount devzone-agent --dry-run=client -o yaml" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'kind: ServiceAccount' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "account_allow : devzone-agent RoleBinding to edit, account set up first" {
    (
        set -e
        source "$KUBE_ACCOUNT"
        account_allow docker-desktop devzone-postgres
    ) || false
    grep -qF -- "--context docker-desktop -n devzone-postgres create rolebinding devzone-agent --clusterrole=edit --serviceaccount=devzone-system:devzone-agent" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'kind: RoleBinding' "$BATS_TEST_TMPDIR/apply.log" || false
    # The account (devzone-system namespace + ServiceAccount) is set up first
    grep -q 'create namespace devzone-system' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'create serviceaccount devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "account_remove : RoleBinding deleted in the namespace" {
    (
        set -e
        source "$KUBE_ACCOUNT"
        account_remove docker-desktop devzone-postgres
    ) || false
    grep -qF -- "--context docker-desktop -n devzone-postgres delete rolebinding devzone-agent --ignore-not-found" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "account_token : 24 h token written to the devzone context of ~/.kube/config" {
    (
        set -e
        source "$KUBE_ACCOUNT"
        account_token docker-desktop
    ) || false
    grep -qF -- "--context docker-desktop create token devzone-agent -n devzone-system --duration=24h" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    # User devzone-agent with the token, cluster entry copied, devzone context
    # on the same cluster as the host context
    grep -qx 'user: devzone-agent --token=token-test' "$HOME/.kube/config" || false
    grep -qx 'cluster: cluster-hote --server=https://127.0.0.1:6443' "$HOME/.kube/config" || false
    grep -qx 'context: devzone --cluster=cluster-hote --user=devzone-agent' "$HOME/.kube/config" || false
}

@test "account_token : container kind cluster → kubeconfig ~/.kube/config" {
    (
        set -e
        source "$KUBE_ACCOUNT"
        account_token kind-devzone
    ) || false
    grep -qF -- "--kubeconfig=$HOME/.kube/config --context kind-devzone create token devzone-agent" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'context: devzone --cluster=kind-devzone --user=devzone-agent' "$HOME/.kube/config" || false
}

@test "kube-account.sh jeton : without a chosen services cluster, nothing runs" {
    run bash "$KUBE_ACCOUNT" jeton
    [ "$status" -eq 0 ] || false
    [ ! -s "$BATS_TEST_TMPDIR/kubectl.log" ] || false
}

@test "kube-account.sh jeton : account set up and token renewed" {
    printf 'cluster=docker-desktop\n' >"$DEVZONE_ETAT"
    run bash "$KUBE_ACCOUNT" jeton
    [ "$status" -eq 0 ] || false
    grep -q 'create namespace devzone-system' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qF -- "--context docker-desktop create token devzone-agent -n devzone-system --duration=24h" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'user: devzone-agent --token=token-test' "$HOME/.kube/config" || false
}

@test "kube-account.sh : without argument, refusal and usage" {
    run bash "$KUBE_ACCOUNT"
    [ "$status" -eq 1 ] || false
    [[ "$output" == *"kube-account : jeton"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/kubectl.log" ] || false
}

@test "kube-account.sh jeton : catches up the existing devzone namespaces (idempotent)" {
    printf 'cluster=docker-desktop\n' >"$DEVZONE_ETAT"
    printf 'namespace/devzone-mysql\nnamespace/devzone-gitlab\n' >"$BATS_TEST_TMPDIR/namespaces"
    run bash "$KUBE_ACCOUNT" jeton
    [ "$status" -eq 0 ] || false
    [ "$(grep -c 'get namespaces -l app.kubernetes.io/managed-by=devzone' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-mysql create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-gitlab create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c 'kind: RoleBinding' "$BATS_TEST_TMPDIR/apply.log")" -eq 2 ] || false
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/apply.log"
    run bash "$KUBE_ACCOUNT" jeton
    [ "$status" -eq 0 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-mysql create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c -- '--context docker-desktop -n devzone-gitlab create rolebinding devzone-agent' "$BATS_TEST_TMPDIR/kubectl.log")" -eq 1 ] || false
    [ "$(grep -c 'kind: RoleBinding' "$BATS_TEST_TMPDIR/apply.log")" -eq 2 ] || false
}
